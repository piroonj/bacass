#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/bacass
========================================================================================
 nf-core/bacass Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/bacass
----------------------------------------------------------------------------------------
*/


def helpMessage() {
    log.info nfcoreHeader()
    log.info"""
    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/bacass --input input.csv --kraken2db 'path-to-kraken2db' -profile docker

    Mandatory arguments:
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test and more.
      --input                       The design file used for running the pipeline in TSV format.

    Pipeline arguments:
      --assembler                   Default: "Unicycler", Available: "Canu", "Flye", "Miniasm", "Unicycler". Short & Hybrid assembly always runs "Unicycler".
      --assembly_type               Default: "Short", Available: "Short", "Long", "Hybrid".
      --kraken2db                   Path to Kraken2 Database directory
      --prokka_args                 Advanced: Extra arguments to Prokka (quote and add leading space)
      --unicycler_args              Advanced: Extra arguments to Unicycler (quote and add leading space)
      --canu_args                   Advanced: Extra arguments for Canu assembly (quote and add leading space)
      --flye_args                   Advanced: Extra arguments for Flye assembly (quote and add leading space) e.g. "--plasmid --meta"

    Other options:
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.
      
   Skipping options:
      --skip_annotation             Skips the annotation with Prokka
      --skip_kraken2                Skips the read classification with Kraken2
      --skip_polish                 Skips polishing long-reads with Nanopolish or Medaka
      --skip_pycoqc                 Skips long-read raw signal QC

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help message
if (params.help){
    helpMessage()
    exit 0
}

// see https://ccb.jhu.edu/software/kraken2/index.shtml#downloads


if(!params.skip_kraken2){
    if(params.kraken2db){
      kraken2db = file(params.kraken2db)
    } else {
      exit 1, "Missing Kraken2 DB arg"
    }
}

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}

if( workflow.profile == 'awsbatch') {
  // AWSBatch sanity checking
  if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
  // Check outdir paths to be S3 buckets if running on AWSBatch
  // related: https://github.com/nextflow-io/nextflow/issues/813
  if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
  // Prevent trace files to be stored on S3 since S3 does not support rolling files.
  if (workflow.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = Channel.fromPath(params.multiqc_config)
ch_output_docs = Channel.fromPath("$baseDir/docs/output.md")

//Check whether we have a design file as input set
if(!params.input){
    exit 1, "Missing Design File - please see documentation how to create one."
} else {
    //Design file looks like this
    // ID R1 R2 Long-ReadFastQ Fast5Path GenomeSize
    // ID is required, everything else (can!) be optional and causes some pipeline components to turn off!
    // Tapping the parsed input design to multiple channels to get some data to specific downstream processes that don't need full information!
    Channel
    .fromPath(params.input)
    .splitCsv(header: true, sep:'\t')
    .map { col -> // mapping info from each col
           def id = "${col.ID}" 
           def r1 = returnFile("${col.R1}")
           def r2 = returnFile("${col.R2}")
           def lr = returnFile("${col.LongFastQ}")
           def f5 = returnFile("${col.Fast5}")
           def genomeSize = "5m"
           tuple(id,r1,r2,lr,f5,genomeSize)
    }
    .dump(tag: "input")
    .tap {ch_all_data; ch_all_data_for_fast5; ch_all_data_for_genomesize}
    .map { id,r1,r2,lr,f5,gs -> 
    tuple(id,r1,r2) 
    }
    .filter{ id,r1,r2 -> 
    r1 != 'NA' && r2 != 'NA'}
    //Filter to get rid of R1/R2 that are NA
    .into {ch_for_short_trim; ch_for_fastqc}
    //Dump long read info to different channel! 
    ch_all_data
    .map { id, r1, r2, lr, f5, genomeSize -> 
            tuple(id, file(lr))
    }
    .dump(tag: 'longinput')
    .into {ch_for_long_trim; ch_for_nanoplot; ch_for_pycoqc; ch_for_nanopolish; ch_for_long_fastq}

    //Dump fast5 to separate channel
    ch_all_data_for_fast5
    .map { id, r1, r2, lr, f5, genomeSize -> 
            tuple(id, f5)
    }
    .filter {id, fast5 -> 
        fast5 != 'NA'
    }
    .into {ch_fast5_for_pycoqc; ch_fast5_for_nanopolish}

    //Dump genomeSize to separate channel, too
    ch_all_data_for_genomesize
    .map { id, r1, r2, lr, f5, genomeSize -> 
    tuple(id,genomeSize)
    }
    .filter{id, genomeSize -> 
      genomeSize != 'NA'
    }
    .into {ch_genomeSize_forCanu; ch_genomeSize_forFlye}
}

// Header log info
log.info nfcoreHeader()
def summary = [:]
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Pipeline Name'] = 'nf-core/bacass'
summary['Run Name'] = custom_runName ?: workflow.runName
summary['Assembler Method'] = params.assembler
summary['Assembly Type'] = params.assembly_type
if (params.kraken2db) summary['Kraken2 DB'] = params.kraken2db 
summary['Extra Prokka arguments'] = params.prokka_args
summary['Extra Unicycler arguments'] = params.unicycler_args
summary['Extra Canu arguments'] = params.canu_args
summary['Extra Flye arguments'] = params.flye_args
if (params.skip_annotation) summary['Skip Annotation'] = params.skip_annotation
if (params.skip_kraken2) summary['Skip Kraken2'] = params.skip_kraken2
if (params.skip_polish) summary['Skip Polish'] = params.skip_polish
if (!params.skip_polish) summary['Polish Method'] = params.polish_method
if (params.skip_pycoqc) summary['Skip PycoQC'] = params.skip_pycoqc
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if(workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Launch dir']       = workflow.launchDir
summary['Output dir'] = params.outdir
summary['Working dir'] = workflow.workDir
summary['Script dir'] = workflow.projectDir
summary['User'] = workflow.userName
if(workflow.profile == 'awsbatch'){
   summary['AWS Region'] = params.awsregion
   summary['AWS Queue'] = params.awsqueue
}
summary['Config Profile'] = workflow.profile

if(params.config_profile_description) summary['Config Description'] = params.config_profile_description
if(params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if(params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if(params.email) {
  summary['E-mail Address']  = params.email
  summary['MultiQC maxsize'] = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "----------------------------------------------------"


// Check the hostnames against configured profiles
checkHostname()

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-bacass-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/bacass Workflow Summary'
    section_href: 'https://github.com/nf-core/bacass'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}

//Check compatible parameters
if(("${params.assembler}" == 'canu' || "${params.assembler}" == 'miniasm' || "${params.assembler}" == 'flye') && ("${params.assembly_type}" == 'short' || "${params.assembly_type}" == 'hybrid')){
    exit 1, "Canu, Flye, and Miniasm can only be used for long read assembly and neither for Hybrid nor Shortread assembly!"
}

//TODO: filter short reads with min length = 50 bp (set in skewer)
//TODO: filter long rads with min length = 200 bp (longFilt)

/* Trim and combine short read read-pairs per sample. Similar to nf-core vipr
 */
process trim_and_combine {

    tag "$sample_id"
    publishDir "${params.outdir}/${sample_id}/1.Trimming/short_reads/", mode: 'copy'

    input:
    set sample_id, file(r1), file(r2) from ch_for_short_trim

    output:
    set sample_id, file("${sample_id}_clean_R1.fastq.gz"), file("${sample_id}_clean_R2.fastq.gz") into (ch_short_for_kraken2, ch_short_for_unicycler, ch_short_for_fastqc)
    // not keeping logs for multiqc input. for that to be useful we would need to concat first and then run skewer
    file ("${sample_id}_clean_R1.fastq.gz.seqstats.txt") 
    file ("${sample_id}_clean_R2.fastq.gz.seqstats.txt") 
    
    script:
    """
    # loop over readunits in pairs per sample
    pairno=0
    echo "${r1} ${r2}" | xargs -n2 | while read fq1 fq2; do
	skewer --quiet -t ${task.cpus} -m pe -q 3 -n -z \$fq1 \$fq2;
    done
    cat \$(ls *trimmed-pair1.fastq.gz | sort) >> ${sample_id}_trm-cmb.R1.fastq.gz
    cat \$(ls *trimmed-pair2.fastq.gz | sort) >> ${sample_id}_trm-cmb.R2.fastq.gz
    fastp -M 30 -f 7 --cut_tail -i ${sample_id}_trm-cmb.R1.fastq.gz -I ${sample_id}_trm-cmb.R2.fastq.gz -o ${sample_id}_clean_R1.fastq.gz -O ${sample_id}_clean_R2.fastq.gz
    seqstats ${sample_id}_clean_R1.fastq.gz > ${sample_id}_clean_R1.fastq.gz.seqstats.txt
    seqstats ${sample_id}_clean_R2.fastq.gz > ${sample_id}_clean_R2.fastq.gz.seqstats.txt
    """
}


//AdapterTrimming for ONT reads
process adapter_trimming {
    label 'medium'
    publishDir "${params.outdir}/${sample_id}/1.Trimming/long_reads/", mode: 'copy', pattern: '*.gz'
    publishDir "${params.outdir}/${sample_id}/1.Trimming/long_reads/", mode: 'copy', pattern: '*.txt'

    when: params.assembly_type == 'hybrid' || params.assembly_type == 'long'

    input:
    set sample_id, file(lr) from ch_for_long_trim

    output:
    set sample_id, file("${sample_id}.trimmed.min500.fastq") into (ch_long_hy_trimmed_unicycler, ch_long_trimmed_unicycler, ch_long_trimmed_flye, ch_long_trimmed_canu, ch_long_trimmed_miniasm, ch_long_trimmed_consensus, ch_long_trimmed_nanopolish, ch_long_trimmed_kraken, ch_long_trimmed_medaka)
    file ("v_porechop.txt") into ch_porechop_version
    file ("${sample_id}.trimmed.min500.seqstats.txt") 
    file ("${sample_id}.trimmed.min500.fastq.gz")

    when: !('short' in params.assembly_type)

    script:
    """
    porechop -i "${lr}" -t "${task.cpus}" -o ${sample_id}.trimmed.fastq
    filtlong --min_length 500 ${sample_id}.trimmed.fastq > ${sample_id}.trimmed.min500.fastq
    cat ${sample_id}.trimmed.min500.fastq | gzip > ${sample_id}.trimmed.min500.fastq.gz
    seqstats ${sample_id}.trimmed.min500.fastq.gz > ${sample_id}.trimmed.min500.seqstats.txt
    porechop --version > v_porechop.txt
    """
}

/*
 * STEP 1 - FastQC FOR SHORT READS
*/
process fastqc {
    label 'small'
    tag "$sample_id"
    publishDir "${params.outdir}/${sample_id}/2.Reads_QC/short_reads/FastQC", mode: 'copy'

    input:
    set sample_id, file(fq1), file(fq2) from ch_short_for_fastqc

    output:
    file "*_fastqc.{zip,html}" into ch_fastqc_results

    script:
    """
    fastqc -t ${task.cpus} -q ${fq1} ${fq2}
    """
}

/*
 * Quality check for nanopore reads and Quality/Length Plots
 */
process nanoplot {
    label 'medium'
    tag "$sample_id"
    publishDir "${params.outdir}/${sample_id}/2.Reads_QC/long_reads/NanoPlot", mode: 'copy'

    when: (params.assembly_type != 'short')

    input:
    set sample_id, file(lr) from ch_for_nanoplot 

    output:
    file '*.png'
    file '*.html'
    file '*.txt'
    file '*.gz'

    script:
    """
    NanoPlot -t "${task.cpus}" --title "${sample_id}" --loglength -c darkblue --fastq ${lr} --raw
    """
}


/** Quality check for nanopore Fast5 files
*/

process pycoqc{
    label 'medium'

    tag "$sample_id"
    publishDir "${params.outdir}/${sample_id}/2.Reads_QC/long_reads/PycoQC", mode: 'copy'

    when: (params.assembly_type == 'hybrid' || params.assembly_type == 'long') && !params.skip_pycoqc && fast5

    input:
    set sample_id, file(lr), file(fast5) from ch_for_pycoqc.join(ch_fast5_for_pycoqc)

    output:
    set sample_id, file('sequencing_summary.txt') into ch_summary_index_for_nanopolish
    file("pycoQC_${sample_id}*")

    script:
    //Find out whether the sequencing_summary already exists
    if(file("${fast5}/sequencing_summary.txt").exists()){
        run_summary = ''
        prefix = "${fast5}/"
    } else {
        run_summary =  "Fast5_to_seq_summary -f $fast5 -t ${task.cpus} -s './sequencing_summary.txt' --verbose_level 2"
        prefix = ''
    }
    //Barcodes available? 
    barcode_me = file("${fast5}/barcoding_sequencing.txt").exists() ? "-b ${fast5}/barcoding_sequencing.txt" : ''
    """
    $run_summary
    pycoQC -f "${prefix}sequencing_summary.txt" $barcode_me -o pycoQC_${sample_id}.html -j pycoQC_${sample_id}.json
    """
}


/* kraken classification: QC for sample purity, only short end reads for now
 */
process kraken2 {
    label 'large'
    tag "$sample_id"
    publishDir "${params.outdir}/${sample_id}/3.Reads_taxonomy/kraken2/short_reads", mode: 'copy'
//    containerOptions "--bind ${params.kraken2db}"

    input:
    set sample_id, file(fq1), file(fq2) from ch_short_for_kraken2

    output:
    file("${sample_id}_kraken2.kreport")

    when: !params.skip_kraken2

    script:
	"""
    # stdout reports per read which is not needed. kraken.report can be used with pavian
    # braken would be nice but requires readlength and correspondingly build db
	kraken2 --threads ${task.cpus} --paired --db ${kraken2db} --report ${sample_id}_kraken2.kreport ${fq1} ${fq2} | gzip > kraken2.out.gz
	"""
}

/* kraken classification: QC for sample purity, only short end reads for now
 */
process kraken2_long {
    label 'large'
    tag "$sample_id"
    publishDir "${params.outdir}/${sample_id}/3.Reads_taxonomy/kraken2/long_reads", mode: 'copy'
//    containerOptions "--bind ${params.kraken2db}"

    input:
    set sample_id, file(lr) from ch_long_trimmed_kraken

    output:
    file("${sample_id}_kraken2.kreport")

    when: !params.skip_kraken2

    script:
	"""
    # stdout reports per read which is not needed. kraken.report can be used with pavian
    # braken would be nice but requires readlength and correspondingly build db
	kraken2 --threads ${task.cpus} --db ${kraken2db} --report ${sample_id}_kraken2.kreport ${lr} | gzip > kraken2.out.gz
	"""
}


/* Join channels for unicycler, as trimming the files happens in two separate processes for paralellization of individual steps. As samples have the same sampleID, we can simply use join() to merge the channels based on this. If we only have one of the channels we insert 'NAs' which are not used in the unicycler process then subsequently, in case of short or long read only assembly.
*/ 
if(params.assembly_type == 'hybrid'){
    ch_short_for_unicycler
        .join(ch_long_hy_trimmed_unicycler)
        .dump(tag: 'unicycler')
        .set {ch_short_long_joint_unicycler}
} else {
    ch_short_for_unicycler
        .map{id,R1,R2 -> 
        tuple(id,R1,R2,'NA')}
        .dump(tag: 'unicycler')
        .set {ch_short_long_joint_unicycler}
}

ch_long_trimmed_unicycler
    .map{id,lr -> 
    tuple(id,'NA','NA',lr)}
    .dump(tag: 'unicycler')
    .set {ch_long_joint_unicycler}


/* unicycler (short or hybrid mode!)
 */
process unicycler {
    label 'large'

    tag "$sample_id"
    publishDir "${params.outdir}/${sample_id}/4.Assembly/unicycler/1.assembly", mode: 'copy'

    when: params.assembler == 'unicycler' && params.assembly_type != 'long'

    input:
    set sample_id, file(fq1), file(fq2), file(lrfastq) from ch_short_long_joint_unicycler 

    output:
    set sample_id, file("${sample_id}_assembly.fasta") into (ch_unicycler_quast, ch_unicycler_prokka, ch_unicycler_dfast, ch_unicycler_taxo)
    file("${sample_id}_assembly.gfa")
    file("${sample_id}_assembly.png")
    file("${sample_id}_unicycler.log")
    set sample_id, file("${sample_id}.*_reads.depth.txt") into (ch_unicycler_for_seqdepth_out)
    
    script:
    if (params.assembly_type == 'short'){
        data_param = "-1 $fq1 -2 $fq2"
        """
        unicycler $data_param --threads ${task.cpus} ${params.unicycler_args} --keep 0 -o .
        mv unicycler.log "${sample_id}_unicycler.log"
        # rename so that quast can use the name 
        mv assembly.gfa "${sample_id}_assembly.gfa"
        mv assembly.fasta "${sample_id}_assembly.fasta"
        Bandage image "${sample_id}_assembly.gfa" "${sample_id}_assembly.png"

        bwa index "${sample_id}_assembly.fasta"
        bwa mem -M -t ${task.cpus} "${sample_id}_assembly.fasta" ${fq1} ${fq2} | samtools view -Sb -F1028 | samtools sort -T tmp.sort -o aln.bam
        bedtools genomecov -ibam aln.bam -bg -split | bedtools groupby -g 1 -c 4 -o mean > ${sample_id}.short_reads.depth.txt
        """
    } else if (params.assembly_type == 'hybrid'){
        data_param = "-1 $fq1 -2 $fq2 -l $lrfastq"
        """
        unicycler $data_param --threads ${task.cpus} ${params.unicycler_args} --keep 0 -o .
        mv unicycler.log "${sample_id}_unicycler.log"
        # rename so that quast can use the name 
        mv assembly.gfa "${sample_id}_assembly.gfa"
        mv assembly.fasta "${sample_id}_assembly.fasta"
        Bandage image "${sample_id}_assembly.gfa" "${sample_id}_assembly.png"

        bwa index "${sample_id}_assembly.fasta"
        bwa mem -M -t ${task.cpus} "${sample_id}_assembly.fasta" ${fq1} ${fq2} | samtools view -Sb -F1028 | samtools sort -T tmp.sort -o aln.bam
        bedtools genomecov -ibam aln.bam -bg -split | bedtools groupby -g 1 -c 4 -o mean > ${sample_id}.short_reads.depth.txt
        
        minimap2 -t ${task.cpus} --secondary=no -ax map-ont "${sample_id}_assembly.fasta" ${lrfastq} | samtools sort -@5 -T tmp -o aln.bam
        bedtools genomecov -ibam aln.bam -bg -split | bedtools groupby -g 1 -c 4 -o mean > ${sample_id}.long_reads.depth.txt
        """ 
    }

}

process unicycler_long {
    label 'large'

    tag "$sample_id"
    publishDir "${params.outdir}/${sample_id}/4.Assembly/unicycler/1.assembly_long", mode: 'copy'

    when: params.assembler == 'unicycler' && params.assembly_type == 'long'

    input:
    set sample_id, file(fq1), file(fq2), file(lrfastq) from ch_long_joint_unicycler 

    output:
    file("${sample_id}_assembly.fasta") into (ch_assembly_nanopolish_unicycler,ch_assembly_medaka_unicycler)
    file("${sample_id}_assembly.gfa")
    file("${sample_id}_assembly.png")
    file("${sample_id}_unicycler.log")
    
    script:
    data_param = "-l $lrfastq"

    """
    unicycler $data_param --threads ${task.cpus} ${params.unicycler_args} --keep 0 -o .
    mv unicycler.log ${sample_id}_unicycler.log
    # rename so that quast can use the name 
    mv assembly.gfa ${sample_id}_assembly.gfa
    mv assembly.fasta ${sample_id}_assembly.fasta
    Bandage image ${sample_id}_assembly.gfa ${sample_id}_assembly.png

    minimap2 -t ${task.cpus} --secondary=no -ax map-ont "${sample_id}_assembly.fasta" ${lrfastq} | samtools sort -@5 -T tmp -o aln.bam
    bedtools genomecov -ibam aln.bam -bg -split | bedtools groupby -g 1 -c 4 -o mean > ${sample_id}.long_reads.depth.txt

    """
}

process flye {
    label 'large'

    tag "$sample_id"
    publishDir "${params.outdir}/${sample_id}/4.Assembly/flye/1.assembly_long", mode: 'copy'
    
    input:
    set sample_id, file(lrfastq), val(genomeSize) from ch_long_trimmed_flye.join(ch_genomeSize_forFlye)

    output:
    file("${sample_id}_assembly.fasta") into (ch_assembly_from_fly_for_nanopolish, ch_assembly_from_fly_for_medaka)
    file("${sample_id}_assembly.gfa")
    file("${sample_id}_assembly.png")
    file("${sample_id}_flye.log")
    file("${sample_id}_assembly_info.txt")

    when: params.assembler == 'flye'

    script:
    """
    flye --nano-raw ${lrfastq} --out-dir . --threads ${task.cpus} -i 2 ${params.flye_args}
    # rename so that quast can use the name
    mv assembly.fasta ${sample_id}_assembly.fasta
    mv assembly_graph.gfa ${sample_id}_assembly.gfa
    mv assembly_info.txt ${sample_id}_assembly_info.txt
    mv flye.log ${sample_id}_flye.log
    Bandage image ${sample_id}_assembly.gfa ${sample_id}_assembly.png
    """
    // TODO: add ">chromosome length=5138942 circular=true"
}

process miniasm_assembly {
    label 'large'

    tag "$sample_id"
    publishDir "${params.outdir}/${sample_id}/4.Assembly/miniasm/1.assembly_long", mode: 'copy'
    
    input:
    set sample_id, file(lrfastq) from ch_long_trimmed_miniasm

    output:
    file "${sample_id}_assembly.fasta" into ch_assembly_from_miniasm

    when: params.assembler == 'miniasm'

    script:
    """
    minimap2 -x ava-ont -t "${task.cpus}" "${lrfastq}" "${lrfastq}" > "${lrfastq}.paf"
    miniasm -f "${lrfastq}" "${lrfastq}.paf" > "${lrfastq}.gfa"
    awk '/^S/{print ">"\$2"\\n"\$3}' "${lrfastq}.gfa" | fold > ${sample_id}_assembly.fasta

    """
}

//Run consensus for miniasm, the others don't need it.
process consensus {
    label 'large'

    tag "$sample_id"
    publishDir "${params.outdir}/${sample_id}/4.Assembly/miniasm/1.assembly_long/consensus", mode: 'copy'

    input:
    set sample_id, file(lrfastq) from ch_long_trimmed_consensus
    file(assembly) from ch_assembly_from_miniasm

    output:
    file "${sample_id}_assembly_consensus.fasta" into (ch_assembly_consensus_for_nanopolish, ch_assembly_consensus_for_medaka)

    script:
    """
    minimap2 -x map-ont -t "${task.cpus}" "${assembly}" "${lrfastq}" > assembly.paf
    racon -t "${task.cpus}" "${lrfastq}" assembly.paf "${assembly}" > "${sample_id}_assembly_consensus.fasta"

    """
}

process canu_assembly {
    label 'large'

    tag "$sample_id"
    publishDir "${params.outdir}/${sample_id}/4.Assembly/canu/1.assembly_long", mode: 'copy'

    input:
    set sample_id, file(lrfastq), val(genomeSize) from ch_long_trimmed_canu.join(ch_genomeSize_forCanu)
    
    output:
    file "${sample_id}_assembly.fasta" into (assembly_from_canu_for_nanopolish, assembly_from_canu_for_medaka)

    when: params.assembler == 'canu'

    script:
    """
    canu -p assembly -d canu_out \
        genomeSize="${genomeSize}" -nanopore-raw "${lrfastq}" \
        maxThreads="${task.cpus}" merylMemory="${task.memory.toGiga()}G" \
        merylThreads="${task.cpus}" hapThreads="${task.cpus}" batMemory="${task.memory.toGiga()}G" \
        redMemory="${task.memory.toGiga()}G" redThreads="${task.cpus}" \
        oeaMemory="${task.memory.toGiga()}G" oeaThreads="${task.cpus}" \
        corMemory="${task.memory.toGiga()}G" corThreads="${task.cpus}" ${params.canu_args}
    mv canu_out/assembly.contigs.fasta "${sample_id}_assembly.fasta"

    """
}

//Polishes assembly using FAST5 files
process nanopolish {
    tag "$assembly"
    label 'large'

    publishDir "${params.outdir}/${sample_id}/4.Assembly/${params.assembler}/2.polish_long_reads/nanopolish", mode: 'copy'

    input:
    file(assembly) from ch_assembly_consensus_for_nanopolish.mix(ch_assembly_nanopolish_unicycler,assembly_from_canu_for_nanopolish, ch_assembly_from_fly_for_nanopolish) //Should take either miniasm, canu, flye or unicycler consensus sequence (!)
    set sample_id, file(lrfastq), file(fast5) from ch_long_trimmed_nanopolish.join(ch_fast5_for_nanopolish)

    output:
    file "${sample_id}_polished_assembly.fa"
    set sample_id, file("${sample_id}_polished_assembly.fa") into (nanopolish_quast_ch, nanopolish_prokka_ch, nanopolish_dfast_ch, nanopolish_taxo_ch)
    set sample_id, file("${sample_id}.long_reads.depth.txt") into (ch_nanopolish_for_seqdepth_out)

    when: !params.skip_polish && params.assembly_type == 'long' && params.polish_method != 'medaka'

    script:
    """
    nanopolish index -d "${fast5}" "${lrfastq}"
    minimap2 -ax map-ont -t ${task.cpus} "${assembly}" "${lrfastq}"| \
    samtools sort -o reads.sorted.bam -T reads.tmp -
    samtools index reads.sorted.bam
    nanopolish_makerange.py "${assembly}" | parallel --results nanopolish.results -P "${task.cpus}" nanopolish variants --consensus -o polished.{1}.vcf -w {1} -r "${lrfastq}" -b reads.sorted.bam -g "${assembly}" -t "${task.cpus}" --min-candidate-frequency 0.1
    nanopolish vcf2fasta -g "${assembly}" polished.*.vcf > "${sample_id}_polished_assembly.fa"

    minimap2 -t ${task.cpus} --secondary=no -ax map-ont "${sample_id}_polished_assembly.fa" ${lrfastq} | samtools sort -@5 -T tmp -o aln.bam
    bedtools genomecov -ibam aln.bam -bg -split | bedtools groupby -g 1 -c 4 -o mean > ${sample_id}.long_reads.depth.txt
    """
}

// Filtlong only high quality reads 100x before rabaler + medaka
// I could set maximum limit polish round for rebaler by change the code
// TODO: add new process (or may not apply)


//Polishes assembly
process medaka {
    tag "$assembly"

    publishDir "${params.outdir}/${sample_id}/4.Assembly/${params.assembler}/2.polish_long_reads/medaka", mode: 'copy'

    input:
    file(assembly) from ch_assembly_consensus_for_medaka.mix(ch_assembly_medaka_unicycler,assembly_from_canu_for_medaka,ch_assembly_from_fly_for_medaka) //Should take either miniasm, canu, flye, or unicycler consensus sequence (!)
    set sample_id, file(lrfastq) from ch_long_trimmed_medaka

    output:
    file("${sample_id}_polished_assembly.fa")
    set sample_id, file("${sample_id}_polished_assembly.fa") into (medaka_quast_ch, medaka_prokka_ch, medaka_dfast_ch, medaka_taxo_ch)
    set sample_id, file("${sample_id}.long_reads.depth.txt") into (ch_medaka_for_seqdepth_out)

    when: !params.skip_polish && params.assembly_type == 'long' && params.polish_method == 'medaka'

    script:
    """
    ## rebaler --threads ${task.cpus} ${assembly} ${lrfastq} > rebaler.fasta
    # Racon round 1
    minimap2 -t ${task.cpus} ${assembly} ${lrfastq} > reads.gfa1.paf
    racon -t ${task.cpus} -m 8 -x -6 -g -8 -w 500 ${lrfastq} reads.gfa1.paf ${assembly} > racon1.fasta

    # Racon round 2
    minimap2 -t ${task.cpus} racon1.fasta ${lrfastq} > reads.gfa2.paf
    racon -t ${task.cpus} -m 8 -x -6 -g -8 -w 500 ${lrfastq} reads.gfa2.paf racon1.fasta > racon2.fasta

    # Medaka
    medaka_consensus -i ${lrfastq} -m r941_min_sup_g507 -d racon2.fasta -o results -t ${task.cpus}
    mv results/consensus.fasta ${sample_id}_polished_assembly.fa

    minimap2 -t ${task.cpus} --secondary=no -ax map-ont ${sample_id}_polished_assembly.fa ${lrfastq} | samtools sort -@5 -T tmp -o aln.bam
    bedtools genomecov -ibam aln.bam -bg -split | bedtools groupby -g 1 -c 4 -o mean > ${sample_id}.long_reads.depth.txt
    """
}


/* assembly qc with quast
 */
process quast {
  tag {"$sample_id"}

  publishDir "${params.outdir}/${sample_id}/4.Assembly/${params.assembler}/3.QUAST", mode: 'copy'
  
  input:
  set sample_id, file(fasta) from ch_unicycler_quast.mix(medaka_quast_ch, nanopolish_quast_ch)
  
  output:
  // multiqc only detects a file called report.tsv. to avoid
  // name clash with other samples we need a directory named by sample
  file("${sample_id}_assembly_QC/report.tsv") into quast_logs_ch
  set sample_id, file("${sample_id}_assembly_QC/") into ch_quast_for_final
  file("v_quast.txt") into ch_quast_version

  script:
  """
  quast.py -t ${task.cpus} -o "${sample_id}_assembly_QC" ${fasta}
  quast.py -v > v_quast.txt
  """
}

/*
 * Annotation with prokka
 */
process prokka {
   label 'large'

   tag "$sample_id"

   publishDir "${params.outdir}/${sample_id}/4.Assembly/${params.assembler}/4.Gene_annotation", mode: 'copy'
   
   input:
   set sample_id, file(fasta) from ch_unicycler_prokka.mix(medaka_prokka_ch, nanopolish_prokka_ch)

   output:
   set sample_id, file("Prokka") into ch_prokka_for_final
   // multiqc prokka module is just a stub using txt. see https://github.com/ewels/MultiQC/issues/587
   // also, this only makes sense if we could set genus/species/strain. otherwise all samples
   // are the same
   // file("${sample_id}_annotation/*txt") into prokka_logs_ch

   when: !params.skip_annotation && params.annotation_tool == 'prokka'

   script:
   """
   prokka --cpus ${task.cpus} --prefix "${sample_id}" --outdir Prokka ${params.prokka_args} ${fasta}
   seqstats Prokka/${sample_id}.fna > Prokka/${sample_id}.fna.seqstats.txt
   """
}

process dfast {

   tag "$sample_id"

   publishDir "${params.outdir}/${sample_id}/4.Assembly/${params.assembler}/4.Gene_annotation", mode: 'copy'
   
   input:
   set sample_id, file(fasta) from ch_unicycler_dfast.mix(medaka_dfast_ch, nanopolish_dfast_ch)
   file (config) from Channel.value(params.dfast_config ? file(params.dfast_config) : "")

   output:
   set sample_id, file("Dfas*") into ch_dfast_for_final
   file("Dfast/v_dfast.txt") into ch_dfast_version_for_multiqc
   file("Dfas*")

   when: !params.skip_annotation && params.annotation_tool == 'dfast'

   script:
   """
   dfast --genome ${fasta} --config $config --cpu ${task.cpus} --out Dfast
   dfast &> Dfast/v_dfast.txt 2>&1 || true
   # rename to sampleid
   mv Dfast/genome.embl "Dfast/${sample_id}.embl"
   mv Dfast/genome.gbk "Dfast/${sample_id}.gbk"
   mv Dfast/genome.fna "Dfast/${sample_id}.fna"
   mv Dfast/genome.gff "Dfast/${sample_id}.gff"
   seqstats Dfast/${sample_id}.fna > Dfast/${sample_id}.fna.seqstats.txt
   """
}

/*
 * Final Result and annotations
 */

process final_gene_annotation {
   tag "$sample_id"

   publishDir "${params.outdir}/${sample_id}/5.Final_results/${params.assembler}_${params.assembly_type}/gene_annotation", mode: 'copy'
   
   input:
   set sample_id, file(anno_result) from ch_dfast_for_final.mix(ch_prokka_for_final)

   output:
   file(anno_result)

   script:
   """

   """
}

process final_assembly_qc {
   tag "$sample_id"

   publishDir "${params.outdir}/${sample_id}/5.Final_results/${params.assembler}_${params.assembly_type}", mode: 'copy'
   
   input:

   set sample_id, file(quast_result) from ch_quast_for_final

   output:
   file(quast_result)

   script:
   """

   """
}

process read_depth_ont {
   tag "$sample_id"

   publishDir "${params.outdir}/${sample_id}/5.Final_results/${params.assembler}_${params.assembly_type}/sequencing_depth/", mode: 'copy'
   
   input:
   set sample_id, file(lrdepth) from ch_medaka_for_seqdepth_out.mix(ch_nanopolish_for_seqdepth_out)

   output:
   file("${lrdepth}")

   script:
   """
   """
}

process read_depth_illm {
   tag "$sample_id"

   publishDir "${params.outdir}/${sample_id}/5.Final_results/${params.assembler}_${params.assembly_type}/", mode: 'copy'
   
   input:
   set sample_id, file(illmdepth) from (ch_unicycler_for_seqdepth_out)

   output:
   file("sequencing_depth/")

   script:
   """
   mkdir sequencing_depth
   cp ${illmdepth} sequencing_depth/
   """
}

process kraken2_genome {
   tag "$sample_id"
   label 'large'

   publishDir "${params.outdir}/${sample_id}/5.Final_results/${params.assembler}_${params.assembly_type}/genome_taxonomy_classification", mode: 'copy'
//   containerOptions "--bind ${params.kraken2db}"
   
   input:
   set sample_id, file(fasta) from ch_unicycler_taxo.mix(nanopolish_taxo_ch, medaka_taxo_ch)

   output:
   file("${sample_id}.assembly.taxonomy.representative.txt") 
   file("${sample_id}.assembly.kraken2.kreport") 
  
   when: !params.skip_kraken2
 
   script:
   """
   kraken2_taxonomy_representative.sh ${kraken2db} ${fasta}
   mv assembly.kraken2.kreport ${sample_id}.assembly.kraken2.kreport
   mv assembly.taxonomy.representative.txt ${sample_id}.assembly.taxonomy.representative.txt
   """
}

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
    saveAs: {filename ->
        if (filename.indexOf(".csv") > 0) filename
        else null
    }

    input:
    file quast_version from ch_quast_version
    file porechop_version from ch_porechop_version
    file dfast_version from ch_dfast_version_for_multiqc


    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml
    file "software_versions.csv"

    script:
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    multiqc --version > v_multiqc.txt
    prokka -v 2> v_prokka.txt
    skewer -v > v_skewer.txt
    kraken2 -v > v_kraken2.txt
    Bandage -v > v_bandage.txt
    nanopolish --version > v_nanopolish.txt
    miniasm -V > v_miniasm.txt
    racon --version > v_racon.txt
    samtools --version &> v_samtools.txt 2>&1 || true
    minimap2 --version &> v_minimap2.txt
    NanoPlot --version > v_nanoplot.txt
    canu --version > v_canu.txt
    flye --version > v_flye.txt
    scrape_software_versions.py > software_versions_mqc.yaml
    """
}

/*
 * STEP - MultiQC
 */

process multiqc {
    label 'small'
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file multiqc_config from ch_multiqc_config
    //file prokka_logs from prokka_logs_ch.collect().ifEmpty([])
    file ('quast_logs/*') from quast_logs_ch.collect().ifEmpty([])
    // NOTE unicycler and kraken not supported
    file ('fastqc/*') from ch_fastqc_results.collect().ifEmpty([])
    file ('software_versions/*') from software_versions_yaml.collect()
    file workflow_summary from create_workflow_summary(summary)

    when: 2 == 1

    output:
    file "*multiqc_report.html" into multiqc_report
    file "*_data"
    file "multiqc_plots"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    """
    multiqc -f $rtitle $rfilename --config $multiqc_config -d .
    """
}


/*
 * STEP 3 - Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}


/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/bacass] Successful: $workflow.runName"
    if(!workflow.success){
      subject = "[nf-core/bacass] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if(workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if(workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if(workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if(workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList){
                log.warn "[nf-core/bacass] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/bacass] Could not attach MultiQC report to summary email"
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (params.email) {
        try {
          if( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[nf-core/bacass] Sent summary e-mail to $params.email (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, params.email ].execute() << email_txt
          log.info "[nf-core/bacass] Sent summary e-mail to $params.email (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/pipeline_info/" )
    if( !output_d.exists() ) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
      log.info "${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}"
      log.info "${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}"
      log.info "${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}"
    }

    if(workflow.success){
        log.info "${c_purple}[nf-core/bacass]${c_green} Pipeline completed successfully${c_reset}"
    } else {
        checkHostname()
        log.info "${c_purple}[nf-core/bacass]${c_red} Pipeline completed with errors${c_reset}"
    }

}


def nfcoreHeader(){
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple} nf-core/bacass v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname(){
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if(params.hostnames){
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if(hostname.contains(hname) && !workflow.profile.contains(prof)){
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}

// Return file if it exists, if NA is found this gets treated as a String information
static def returnFile(it) {
    if(it == 'NA') {
        return 'NA'
    } else { 
    if (!file(it).exists()) exit 1, "Warning: Missing file in CSV file: ${it}, see --help for more information"
        return file(it)
    }
}
