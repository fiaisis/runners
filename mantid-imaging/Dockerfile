FROM nvidia/cuda:12.9.1-base-ubuntu24.04

# Install/setup Conda copied from https://github.com/conda-forge/miniforge-images/blob/master/ubuntu/Dockerfile
ARG MINIFORGE_NAME=Miniforge3
ARG MINIFORGE_VERSION=25.11.0-0

ENV CONDA_DIR=/opt/conda
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
ENV PATH=${CONDA_DIR}/bin:${PATH}

RUN apt-get update > /dev/null && \
    apt-get install --no-install-recommends --yes \
        wget bzip2 ca-certificates \
        git \
        tini \
        > /dev/null && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    wget --no-hsts --quiet https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VERSION}/${MINIFORGE_NAME}-${MINIFORGE_VERSION}-Linux-$(uname -m).sh -O /tmp/miniforge.sh && \
    /bin/bash /tmp/miniforge.sh -b -p ${CONDA_DIR} && \
    rm /tmp/miniforge.sh && \
    conda clean --tarballs --index-cache --packages --yes && \
    find ${CONDA_DIR} -follow -type f -name '*.a' -delete && \
    find ${CONDA_DIR} -follow -type f -name '*.pyc' -delete && \
    conda clean --force-pkgs-dirs --all --yes  && \
    echo ". ${CONDA_DIR}/etc/profile.d/conda.sh && conda activate base" >> /etc/skel/.bashrc && \
    echo ". ${CONDA_DIR}/etc/profile.d/conda.sh && conda activate base" >> ~/.bashrc

# Install mantidimaging
RUN mamba env create -f https://raw.githubusercontent.com/mantidproject/mantidimaging/stable/environment.yml -y -c conda-forge requests opencv

# Make sure the environment is activated:
RUN echo "conda activate mantidimaging" >> ~/.bashrc
ENV PATH /opt/conda/envs/mantidimaging/bin:$PATH

# Create a shell script to run the python command:
RUN echo '#!/bin/bash\npython -c "$@"' > /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Set the entrypoint:
ENTRYPOINT ["/entrypoint.sh"]