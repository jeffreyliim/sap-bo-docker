# Installing Oracle
FROM centos:centos7 AS oracleprep

LABEL author="jeffrey.lim" \
      install="SAP Business Objects" \
      platform="Centos 7" \
      license="" \
      description="Docker file for FICO SAP Business Objects" \
      terms=""

USER root
ENV ORACLE_SOURCE_PATH /source/oracle
ENV SAP_SOURCE_PATH /source/sap
ENV ETC_PROFILE_PATH /etc/profile.d
ENV BO42SP9_INSTALL_PATH /apps/bo/bo42sp9_install
ENV BO42SP9_UNZIP_PATH /apps/bo/bo42sp9_unzip
ENV ORACLE_HOME /usr/lib/oracle/12.2/client64
ENV LD_LIBRARY_PATH $ORACLE_HOME/lib
ENV TNS_ADMIN $ORACLE_HOME/network/admin

COPY oracle $ORACLE_SOURCE_PATH

# Prerequisite
# - /source/oracle/oracle-instantclient12.2-basic-12.2.0.1.0-1.x86_64.rpm
# - /source/oracle/oracle-instantclient12.2-sqlplus-12.2.0.1.0-1.x86_64.rpm
# - /source/oracle/tnsnames.ora

# Install dependencies
RUN yum install -y compat-libstdc++-33.x86_64 glibc-2.17-307.el7.1.i686 compat-libstdc++-33-3.2.3-72.el7.i686 libstdc++.i686 libaio unzip java-1.8.0-openjdk && \
    rpm -i $ORACLE_SOURCE_PATH/oracle-instantclient12.2-basic-12.2.0.1.0-1.x86_64.rpm && \
    rpm -i $ORACLE_SOURCE_PATH/oracle-instantclient12.2-sqlplus-12.2.0.1.0-1.x86_64.rpm

# Add config and fixing dependencies for BO to install
RUN mkdir -p $ORACLE_HOME/network/admin && \
    cp $ORACLE_SOURCE_PATH/tnsnames.ora $ORACLE_HOME/network/admin/tnsnames.ora && \
    cp $ORACLE_HOME/lib/libclntsh.so.12.1 $ORACLE_HOME/lib/libclntsh.so && \
    cp $ORACLE_HOME/lib/libclntshcore.so.12.1 $ORACLE_HOME/lib/libclntshcore.so

# Clean up
RUN rm -rf $ORACLE_SOURCE_PATH

# After Oracle is setup, we will then be allowed to install the BO server
FROM oracleprep as boinstall

RUN useradd -ms /bin/bash falcon
RUN mkdir -p $BO42SP9_INSTALL_PATH $BO42SP9_UNZIP_PATH

# Prerequisite
# - /source/sap/sap_bo_51054876.zip
# - /source/sap/response.ini
# - /source/sap/patchlevel.sh
# Copy install media
COPY sap $SAP_SOURCE_PATH
WORKDIR $SAP_SOURCE_PATH

# Unzip files
RUN unzip sap_bo_51054876.zip -d $BO42SP9_UNZIP_PATH && \
    rm -rf sap_bo_51054876.zip

# Adding patched files and providing permissions to falcon user
# - patchlevel.sh added "exit 0" in line 30
# RUN sed -i "30i exit 0" dunit/product.businessobjects64-4.0-core-32/actions/patchlevel.sh
# - response.ini file replaced with stg/prod config
WORKDIR  $BO42SP9_UNZIP_PATH/DATA_UNITS/BusinessObjectsServer_lnx
RUN yes | cp $SAP_SOURCE_PATH/patchlevel.sh dunit/product.businessobjects64-4.0-core-32/actions/patchlevel.sh && \
    yes | cp $SAP_SOURCE_PATH/response.ini response.ini && \
    chmod -R 777 * && \
    chown -R falcon /apps && \
    chown falcon $ORACLE_HOME/network/admin/tnsnames.ora

USER falcon
ENV LANG=en_US.utf8
ENV LC_ALL=en_US.utf8
ENV TERM=xterm

# Install BO - This step takes the longest and the largest amount of space (26GB)
WORKDIR $BO42SP9_UNZIP_PATH/DATA_UNITS/BusinessObjectsServer_lnx/
RUN ./setup.sh -r ./response.ini -q -InstallDir $BO42SP9_INSTALL_PATH && \
    ls -a $BO42SP9_INSTALL_PATH && \
    echo "************ END OF INSTALL ************"

# DISABLING THIS BLOCK BECAUSE THE BUILD IS TAKING TOO MUCH SPACE, CANT AFFORD ANY "COPIES" AND "RUNS" that create more layers
USER root
#
## Only the files from boinstall will be used in the final image
FROM oracleprep
#
RUN useradd -ms /bin/bash falcon
COPY --from=boinstall $BO42SP9_INSTALL_PATH $BO42SP9_INSTALL_PATH
USER falcon
ENV LANG=en_US.utf8
ENV LC_ALL=en_US.utf8

# Ports
EXPOSE 8080 6400 6405

# Persistence Volumes
VOLUME $BO42SP9_INSTALL_PATH/sap_bobj/logging
VOLUME $BO42SP9_INSTALL_PATH/sap_bobj/data

CMD $BO42SP9_INSTALL_PATH/sap_bobj/tomcatstartup.sh && $BO42SP9_INSTALL_PATH/sap_bobj/startservers && /usr/bin/tail -f
