#!/usr/bin/env bash

kraken2db=$1
fasta=$2

samtools faidx ${fasta}
bedtools getfasta -fi ${fasta} -fo splitted_200base.fasta -bed <(bedtools makewindows -w 200 -g ${fasta}.fai)

kraken2 --db ${kraken2db} --report assembly.kraken2.kreport splitted_200base.fasta > assembly.kraken2.output

cat assembly.kraken2.output | kraken-report-edit.perl --db ${kraken2db} | awk -v ctg=assembly 'BEGIN{OFS=FS="\t"}{if($1>1 && ($4=="G"||$4=="S"||$4=="U")) print ctg,$1,$2,$4,$5,$6}' > assembly.taxonomy.representative.txt

for ctg in $(cut -f1 ${fasta}.fai); do grep $ctg":" assembly.kraken2.output | kraken-report-edit.perl --db ${kraken2db} | awk -v ctg=$ctg 'BEGIN{OFS=FS="\t"}{if($1>1 && ($4=="G"||$4=="S"||$4=="U")) print ctg,$1,$2,$4,$5,$6}' ; done >> assembly.taxonomy.representative.txt

