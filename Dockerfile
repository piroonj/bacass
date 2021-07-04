FROM nfcore/base:1.7
LABEL authors="Andreas Wilm, Alexander Peltzer" \
      description="Docker image containing all requirements for nf-core/bacass pipeline"

COPY environment.yml /
RUN conda env create -f /environment.yml && conda clean -a
RUN conda env create -n medaka -c bioconda --quiet medaka=1.4.3 && conda clean -a
RUN conda env create -n dfast -c bioconda --quiet dfast=1.2.14 && conda clean -a
# for bandage :/ otherwise it complains about missing libGL.so.1
RUN apt-get install -y libgl1-mesa-glx && apt-get clean -y
ENV PATH /opt/conda/envs/nf-core-bacass-1.1.0/bin:/opt/conda/envs/medaka/bin:/opt/conda/envs/dfast/bin:$PATH
RUN dfast_file_downloader.py --protein dfast
RUN dfast_file_downloader.py --cdd Cog --hmm TIGR
