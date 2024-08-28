FROM condaforge/mambaforge:24.3.0-0

# Install mantid (in-container) dependencies
RUN apt-get update && apt-get install libgl1 -y

# Install mantid
ARG MANTID_VERSION
RUN mamba create -y -n mantid -c mantid -c conda-forge mantid=${MANTID_VERSION} requests

# Install custom properties
COPY ./Mantid/Mantid.user.properties /root/.mantid/Mantid.user.properties

# Make sure the environment is activated:
RUN conda init bash
RUN echo "conda activate mantid" > ~/.bashrc
ENV PATH /opt/conda/envs/mantid/bin:$PATH

# Run the DownloadInstrument algorithm to get instrument definitions
RUN python -c "from mantid.simpleapi import DownloadInstrument;DownloadInstrument()"

# Create a shell script to run the python command:
RUN echo '#!/bin/bash\npython -c "$@"' > /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Set the entrypoint:
ENTRYPOINT ["/entrypoint.sh"]