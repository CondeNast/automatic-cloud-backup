#!/bin/bash

CONFIG="$HOME/.backup.sh.vars"
ATTACHMENTS="true"
FILEPREFIX="JIRA"

umask 0077 

if [ -r "$CONFIG" ]; then
    . $CONFIG
    DOWNLOAD_URL="https://${INSTANCE}"
    INSTANCE_PATH=$INSTANCE
else
    echo "Usable to load $CONFIG! Please create one based on backup.sh.vars.example"
    exit 1
fi

while [[ $# -gt 1 ]]
do
    key="$1"

    case $key in
        -s|--source)
            if [[  $2 == "wiki" ]] || [[ $2 == "confluence" ]]; then
                INSTANCE_PATH=$INSTANCE/wiki
                DOWNLOAD_URL="https://${INSTANCE_PATH}/download"
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

BASENAME=$1
RUNBACKUP_URL="https://${INSTANCE_PATH}/rest/obm/1.0/runbackup"
PROGRESS_URL="https://${INSTANCE_PATH}/rest/obm/1.0/getprogress.json"

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
find $COOKIE_FILE_LOCATION -mtime -1 2> /dev/null |grep $COOKIE_FILE_LOCATION 2>&1 > /dev/null
if [ $? -ne 0 ]; then
    curl --silent --cookie-jar $COOKIE_FILE_LOCATION -X POST "https://${INSTANCE}/rest/auth/1/session" -d "{\"username\": \"$USERNAME\", \"password\": \"$PASSWORD\"}" -H 'Content-Type: application/json' --output /dev/null
fi

# The $BKPMSG variable will print the error message, you can use it if you're planning on sending an email
BKPMSG=$(curl -s --cookie $COOKIE_FILE_LOCATION --header "X-Atlassian-Token: no-check" -H "X-Requested-With: XMLHttpRequest" -H "Content-Type: application/json"  -X POST $RUNBACKUP_URL -d '{"cbAttachments":"${ATTACHMENTS}" }' )

# Checks if we were authorized to create a new backup
if [ "$(echo "$BKPMSG" | grep -c Unauthorized)" -ne 0 ]  || [ "$(echo "$BKPMSG" | grep -ic "<status-code>401</status-code>")" -ne 0 ]; then
    echo "ERROR: authorization failure"
    exit
fi

#Checks if the backup exists every 10 seconds, 20 times. If you have a bigger instance with a larger backup file you'll probably want to increase that.
for (( c=1; c<=$PROGRESS_CHECKS; c++ )) do
    PROGRESS_JSON=$(curl -s --cookie $COOKIE_FILE_LOCATION $PROGRESS_URL)
    FILE_NAME=$(echo "$PROGRESS_JSON" | sed -n 's/.*"fileName"[ ]*:[ ]*"\([^"]*\).*/\1/p')

    echo $PROGRESS_JSON|grep error > /dev/null && break

    if [ ! -z "$FILE_NAME" ]; then
        break
    fi
    sleep $SLEEP_SECONDS
done

# If after 20 attempts it still fails it ends the script.
if [ -z "$FILE_NAME" ]; then
    exit
else
    # Download the new way, starting Nov 2016
    curl -s -S -L --cookie $COOKIE_FILE_LOCATION "$DOWNLOAD_URL/$FILE_NAME" -o "$OUTFILE"
fi
