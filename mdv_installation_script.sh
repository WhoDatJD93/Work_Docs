#!/bin/bash


##### Environmental Variables for MDV installation #####
export CTG_RTTCT=/apps1/tomcat3;                 # Root of the tomcat folder where the content resides
export CTG_RTDATA=/usr/data/pbadata;             # Root of the data where the configuration and data will reside
export CTG_DEPLOY=/user/data/pbadata/deployment/mdv5          # Root directory of the deployment artifacts and backups
export CTG_TODAY=$(date +'%Y%m%d');         # YYYYMMDD output
export CTG_TOMUSER="ctg-tomcat";         ## Check and Make sure that this is the correct tomcat user for server
export CTG_ASSET="las5";            ## Check and make sure that the Server name is the one that the tomcat service is hosted on
export CTG_SERVICENAME="tomcat3";           ## Check and make sure that the Service name is correct for this application




##### Save Prior Artifacts for old MDV ######

sudo mkdir -p "${CTG_DEPLOY}";
sudo chown -R "${CTG_TOMUSER}":"${CTG_TOMUSER}" "${CTG_DEPLOY}";
cp -r <my_sources> "${CTG_DEPLOY}";


##### Perform a Backup of Tomcat, Stop service/application then create backup #####

sudo systemctl stop "${CTG_SERVICENAME}";
sudo systemctl status "${CTG_SERVICENAME}";

##### Check to make sure that tomcat service is not running in PS output #####
##### Verify that port for tomcat is not listening: ######

ps -ef |grep tomcat
sudo ss -tulnp |grep tomcat;
# Or/If command ss is not available #
sudo netstat -tulnp |grep tomcat;


###### Create Backup Directory, then Perfom Backups of MDV4.* configuration settings, SystemD files for old tomcat #####
  
mkdir -p "${CTG_DEPLOY}/backups/${CTG_ASSET}/${CTG_TODAY}";
tar cvfz "${CTG_DEPLOY}/backups/${CTG_ASSET}/${CTG_TODAY}/${CTG_TODAY}_${CTG_SERVICENAME}.tgz";
tar cvfz "${CTG_DEPLOY}/backups/${CTG_ASSET}/${CTG_TODAY}/${CTG_TODAY}_mdv4_configs.tgz" "${CTG_RTDATA}/mdv4_config";
cp /etc/systemd/system/tomcat* "/usr/data/pbadata/backups/las5/${CTG_TODAY}/";




