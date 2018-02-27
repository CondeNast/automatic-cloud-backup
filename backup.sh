#!/bin/bash

CONFIG="$HOME/.backup.sh.vars"
ATTACHMENTS="true"
FILEPREFIX="JIRA"

umask 0077 

if [[ -z $USERNAME || -z $PASSWORD || -z $INSTANCE || -z $LOCATION || -z $TIMESTAMP || -z $TIMEZONE || -z $SLEEP_SECONDS || -z $PROGRESS_CHECKS ]]; then
    if [ -r "$CONFIG" ]; then
        . $CONFIG
    else
       echo "Usable to load $CONFIG! Please create one based on backup.sh.vars.example"
       exit 1
    fi
fi

DOWNLOAD_URL="https://${INSTANCE}"
RUNBACKUP_URL="https://${INSTANCE}/rest/backup/1/export/runbackup"

while [[ $# -gt 1 ]]
do
    key="$1"

    case $key in
        -s|--source)
            if [[  $2 == "wiki" ]] || [[ $2 == "confluence" ]]; then
                RUNBACKUP_URL="https://${INSTANCE}/wiki/rest/obm/1.0/runbackup"
                PROGRESS_URL="https://${INSTANCE}/wiki/rest/obm/1.0/getprogress.json"
                DOWNLOAD_URL="https://${INSTANCE}/wiki/download"
                FILEPREFIX="CONFLUENCE"
            fi
            shift # past argument
            ;;
        -a|--attachments)
            if [[  $2 == "false" ]]; then
                ATTACHMENTS="false"
            fi
            shift # past argument
            ;;
        -t|--timestamp)
            if [[  $2 == "false" ]]; then
                TIMESTAMP=false
            fi
            shift # past argument
            ;;

    esac
    shift # past argument or value
done

# Grabs cookies and generates the backup on the UI. 
TODAY=$(TZ=$TIMEZONE date +%Y%m%d)

#Check if we should overwrite the previous backup or append a timestamp to 
#prevent just that. The former is useful when an external backup program handles 
#backup rotation.
if [ $TIMESTAMP = "true" ]; then
    OUTFILE="${LOCATION}/$FILEPREFIX-backup-${TODAY}.zip"
elif [ $TIMESTAMP = "false" ]; then
    OUTFILE="${LOCATION}/$FILEPREFIX-backup.zip"
else
    echo "ERROR: invalid value for TIMESTAMP: should be either \"true\" or \"false\""
    exit 1
fi

COOKIE_FILE_LOCATION="$HOME/.backup.sh-cookie"

# Only generate a new cookie if one does not exist, or if it is more than 24 
# hours old. This is to allow reuse of the same cookie until a new backup can be 
# triggered.
echo "Checking for cookie" #DEBUG
find $COOKIE_FILE_LOCATION -mtime -1 2> /dev/null |grep $COOKIE_FILE_LOCATION 2>&1 > /dev/null
if [ $? -ne 0 ]; then
    echo "Generating cookie" #DEBUG
    curl --silent --cookie-jar $COOKIE_FILE_LOCATION -X POST "https://${INSTANCE}/rest/auth/1/session" -d "{\"username\": \"$USERNAME\", \"password\": \"$PASSWORD\"}" -H 'Content-Type: application/json' --output /dev/null
fi

# The $BKPMSG variable will print the error message, you can use it if you're planning on sending an email
echo "Triggering backup" #DEBUG
BKPMSG=$(curl -s --cookie $COOKIE_FILE_LOCATION --header "X-Atlassian-Token: no-check" -H "X-Requested-With: XMLHttpRequest" -H "Content-Type: application/json"  -X POST $RUNBACKUP_URL -d "{\"cbAttachments\":\"${ATTACHMENTS}\" }" )

echo $BKPMSG ; # DEBUG

# Checks if we were authorized to create a new backup
if [ "$(echo "$BKPMSG" | grep -c Unauthorized)" -ne 0 ]  || [ "$(echo "$BKPMSG" | grep -ic "<status-code>401</status-code>")" -ne 0 ]; then
    echo "ERROR: authorization failure"
    exit
fi

if [[ $FILEPREFIX == 'JIRA' ]]; then
    TASK_ID=$(curl -s --cookie $COOKIE_FILE_LOCATION -H "Accept: application/json" -H "Content-Type: application/json" https://${INSTANCE}/rest/backup/1/export/lastTaskId)
    PROGRESS_URL="https://${INSTANCE}/rest/backup/1/export/getProgress?taskId=${TASK_ID}"
fi
    
# Different methods for checking status and downloading backups for confluence and jira
#Checks if the backup exists every $SLEEP_SECONDS seconds, $PROGRESS_CHECKS times.
echo "Polling for backup" #DEBUG
for (( c=1; c<=$PROGRESS_CHECKS; c++ )) do
    PROGRESS_JSON=$(curl -s --cookie $COOKIE_FILE_LOCATION $PROGRESS_URL)
    FILE_NAME=$(echo "$PROGRESS_JSON" | sed -n 's/.*"fileName"[ ]*:[ ]*"\([^"]*\).*/\1/p')

    echo $PROGRESS_JSON|grep error > /dev/null && break
    echo $PROGRESS_JSON ; # DEBUG

    if [ ! -z "$FILE_NAME" ]; then
        break
    fi
    sleep $SLEEP_SECONDS
done
 
# If after $PROGRESS_CHECKS attempts it still fails it ends the script.
if [ -z "$FILE_NAME" ]; then
    exit
else

# Download the new way, starting Nov 2016
echo  "curl -s -S -L --cookie $COOKIE_FILE_LOCATION "$DOWNLOAD_URL/$FILE_NAME" -o "$OUTFILE"" ; # DEBUG
    curl -s -S -L --cookie $COOKIE_FILE_LOCATION "$DOWNLOAD_URL/$FILE_NAME" -o "$OUTFILE"
fi
