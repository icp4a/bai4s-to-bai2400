#!/bin/bash
##################################################################
# Licensed Materials - Property of IBM
#  5737-I23
#  Copyright IBM Corp. 2024. All Rights Reserved.
#  U.S. Government Users Restricted Rights:
#  Use, duplication or disclosure restricted by GSA ADP Schedule
#  Contract with IBM Corp.
##################################################################

# functions to perform BAI4S to 24.0.0 migration

#Elasticsearch functions
function initBAI4Senv () {
    # Depends on BAI4S_INSTALL_DIR
    echo "Get BAI4S credentials for elasticsearch"
    # shellcheck disable=SC1091
    source "${BAI4S_INSTALL_DIR?}/.env"
    ELASTICSEARCH_URL="https://${ELASTICSEARCH_EXTERNAL_HOSTNAME:?}:${ELASTICSEARCH_PORT:-443}"
    echo "ELASTICSEARCH_URL=${ELASTICSEARCH_URL}"
    echo "ELASTICSEARCH_USERNAME=${ELASTICSEARCH_USERNAME:?}"
    ELASTICSEARCH_PASSWORD=$(decode-base64 "${ELASTICSEARCH_PASSWORD}")
    echo "ELASTICSEARCH_PASSWORD=${ELASTICSEARCH_PASSWORD}"
}

function patchBAI4S() {
    # patch ES config to add path.repo and restart ES
    echo "Patching ElasticSearch config file."
    echo 'path.repo: ["/usr/share/elasticsearch/data/snapshots"]' >> "${BAI4S_INSTALL_DIR?}/config/kibana/elasticsearch.yml"
    # restart es
    read -r -p "Ok to restart ElasticSearch? [y/N] " -n 1
    echo
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        docker-compose-cli restart elasticsearch
    else
        echo "ElasticSearch not restarted."
    fi
}

function docker-compose-cli() {
  # docker-compose broke compatibility with .env policy
  if docker-compose --help | grep -q 'env-file PATH'  ; then
    docker-compose -f "${BAI4S_INSTALL_DIR}/data/bai.yml" --env-file "${BAI4S_INSTALL_DIR}/.env" "$@"
  else
    docker-compose -f "${BAI4S_INSTALL_DIR}/data/bai.yml" "$@"
  fi
}

function deleteSnapshot() {
    read -r -p "Ok to delete BAIS snapshot on ElasticSearch? [y/N] " -n 1
    echo
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        curlDEL-ES "_snapshot/main/bai4s"
        echo
    else
        echo "Operation canceled."
    fi
}
function makeSnapshot() {
    echo 'Created a repo "main" and snapshot "bai4s"' 
    # create repository
    curlPUT-ES "_snapshot/main" '{
        "type": "fs",
        "settings": {
          "location": "/usr/share/elasticsearch/data/snapshots"
        }
      }'
    # create snapshot
    curlPUT-ES "_snapshot/main/bai4s?wait_for_completion=true" '{
        "indices": ".bai*,bawadv*,case*,content*,odm*,process*"
      }'
}
function curlPUT-ES() {
     curl -s -X PUT -u "${ELASTICSEARCH_USERNAME:?}:${ELASTICSEARCH_PASSWORD:?}" --insecure --url "${ELASTICSEARCH_URL:?}/$1" -H 'Content-Type: application/json' -d "$2"
}
function curlDEL-ES() {
     curl -s -X DELETE -u "${ELASTICSEARCH_USERNAME:?}:${ELASTICSEARCH_PASSWORD:?}" --insecure --url "${ELASTICSEARCH_URL:?}/$1" -H 'Content-Type: application/json' 
}
function decode-base64() {
  local text=${1:?Missing string to decode}
  if is-encoded-base64 "${text}"; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
      echo "${text}" | sed -n 's/{base64}\(.*\)/\1/p' | base64 -D
    else
      echo "${text}" | sed -n 's/{base64}\(.*\)/\1/p' | base64 -d
    fi
  else
    echo "${text}"
  fi
}
function is-encoded-base64() {
  local text=${1:?Missing input text}
  if [[ ${text} == "{base64}"* ]]; then
    return 0
  else
    return 1
  fi
}

#Opensearch functions
function getOScredentials() {
    echo "Assuming oc login was successful."
    if [ -z "${NAMESPACE}" ]; then
      read -r -p "Enter namespace of Opensearch installation: " NAMESPACE
    fi
    echo "Using namespace ${NAMESPACE:?}"
    OPENSEARCH_URL="https://$(oc get routes opensearch-route -o jsonpath="{.spec.host}" -n "$NAMESPACE"):443"
    OPENSEARCH_USERNAME=elastic
    OPENSEARCH_PASSWORD=$(oc extract secret/opensearch-ibm-elasticsearch-cred-secret --keys=elastic --to=- -n "$NAMESPACE" 2>/dev/null)
    echo "OS URL: ${OPENSEARCH_URL}"
    echo "OS cred: ${OPENSEARCH_USERNAME} ${OPENSEARCH_PASSWORD}"
    target="https://${OPENSEARCH_USERNAME}:${OPENSEARCH_PASSWORD}@${OPENSEARCH_URL##*://}"
    echo "full url: ${target}"
    # reset NAMESPACE if bad 
    oc project -q "${NAMESPACE}" 2> /dev/null || unset NAMESPACE
}

function copySnapshotToOS() {
    # The directory of BAI4S snapshot is volumes/elasticsearch/snapshots
    local pod
    pod=$(oc get pods -o name |grep opensearch|grep server|head -1)
    du -sh "${BAI4S_INSTALL_DIR?}/volumes/elasticsearch/snapshots"
    echo "Copy to ${pod}:/workdir/snapshot_storage"
    oc cp "${BAI4S_INSTALL_DIR?}/volumes/elasticsearch/snapshots" "${pod#pod/}:/workdir/snapshot_storage"
}

function deleteIndex() {
    if [[ $(curlHEAD "$1") == 200 ]]; then
      curlDEL "$1"  
    fi   
}

function restoreSnapshotOnOS() {
    printf 'Prepare target cluster\n'
    # save intersting indices
    for i in icp4ba-bai-store-dashboards icp4ba-bai-store-monitoring-sources ; do
        if [[ $(curlHEAD "$i") == 200 ]]; then
          reindex_request="{
            \"source\": {
              \"index\": \"${i}\"
            },
            \"dest\": {
                \"index\": \"orig-${i}\"
            }
          }"
          response=$(curlPOST "_reindex?wait_for_completion=true" "$reindex_request")
        fi   
    done
    # this supress all: curlDEL 'icp4ba*?expand_wildcards=all'
    # supress indices that may be in the way.
    for i in icp4ba-bai-store-dashboards icp4ba-bai-store-goals icp4ba-bai-store-alertdetectionstates \
             icp4ba-bai-store-alerts icp4ba-bai-store-permissions ; do
        deleteIndex "$i"
    done
    # create snapshot repo 
    curlPUT "_snapshot/main" '{
        "type": "fs",
        "settings": {
          "location": "/workdir/snapshot_storage/snapshots"
        }
      }'
    printf '\nRestore snapshot "bai4s"\n' 
    # restore all indices, convert .bai into icp4ba-bai on the fly
    # shellcheck disable=SC2016
    curlPOST "_snapshot/main/bai4s/_restore?wait_for_completion=true" '{
        "rename_pattern": "^.bai-(.+)",
        "rename_replacement": "icp4ba-bai-$1"
      }'
    echo
}
function transformIndices() {
    local indices indicesBai4s index target
    # loop over all data indices
    indicesBai4s=$(curlGET "_cat/indices?h=index"|grep -v 'icp4ba-bai')
    indices=$(curlGET "_cat/indices?h=index"|grep 'icp4ba-bai')
    for index in ${indicesBai4s}; do
      case $index in
        case-summaries-*) processIndex "$index" ;;
        content-timeseries-idx*) processIndex "$index" ;;
        odm-timeseries-idx*) processIndex "$index" ;;
        process-*) processIndex "$index" ;;
        bawadv-summaries-*) processIndex "$index" ;;
      esac
    done
    curlGET "_refresh" > /dev/null
}


function processIndex() {
    # $1 is the index
    local t index mappings target reindex_request response taskID found
    index=${1?Missing index}
    echo "Processing ${index}"

    # find target index
    # bai4s index without trailing date
    found=false
    shortBAI4SIndex=${index%-[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]-[0-9]*}
    for t in ${indices}; do
      if [[ $t =~ $shortBAI4SIndex ]]; then
        # reuse index
        target=$t
        found=true
        curlPUT "${target}/_settings" '{"index":{"refresh_interval":-1,"number_of_replicas":0}}' > /dev/null
        break
      fi  
    done
    if [[ -z $target ]]; then
      # create index 
      target="icp4ba-bai-${index}"  
      # get and fix mapping
      mappings=$(curlGET "${index}/_mappings"| jq -r '.[].mappings|del(..|.omit_norms?)')

      # create index 
      curlPUT "$target" '{
        "settings": '"{\"index\":{\"refresh_interval\":\"-1\",\"number_of_replicas\":\"0\"}}"',
        "mappings": '"$mappings"'
        }'
    fi

    # reindex
    reindex_request="{
            \"source\": {
              \"index\": \"${index}\"
            },
            \"dest\": {
                \"index\": \"${target}\"
            }
        }"
    response=$(curlPOST "_reindex?wait_for_completion=false" "$reindex_request")
    printf "\n>>> Copy %s to %s\n  %s\n" "${index}" "${target}" "${response}"
    taskID=$(echo "$response" | jq -r '.task')
    checkProgress "${target}" "${taskID}"
    # restore refresh
    curlPUT "${target}/_settings" '{"index":{"refresh_interval":null,"number_of_replicas":null}}' > /dev/null
    curlGET "${target}/_refresh" > /dev/null

  # Extract and migrate aliases using jq
    if ! $found ; then 
      printf "\n>>> Processing alias: %s\n" "$alias_name"
      alias_names=$(curlGET "${index}" | jq -r '.[].aliases | keys[]')
      # restore aliases
      for alias_name in $alias_names; do
        curlPOST "_aliases" "
          {
              \"actions\": [
                {\"add\": 
                  {\"index\": \"${target}\",
                  \"alias\": \"icp4ba-bai-${alias_name}\" 
                  }
                }
              ]
          }"
      done
    fi

    # delete old index
    printf "\n>>> Deleting BAI4S index: %s\n" "$index"
    curlDEL "${index}"
    printf "\n------------- Done -------------------\n"


}

# check progress, using task API
function checkProgress() {
    # $1 is index
    # $2 is task id
    local completion response total created message tookMS
    printf "\n>>> Migration status for index: %s" "$1"
    response=$(curlGET "_tasks/$2")
    completion=$(jq -r ".completed" <<< "$response")
    created=$(jq -r ".task.status.created" <<< "$response")
    while [ "${completion}" == 'false' ]; do 
      sleep 5
      response=$(curlGET "_tasks/$2")
      completion=$(jq -r ".completed" <<< "$response")
      created=$(jq -r ".task.status.created" <<< "$response")
      total=$(jq -r ".task.status.total" <<< "$response")
      if [[ "$created" != "0" ]]; then
          echo -ne "Copied documents/total: ${created}/${total}             \r"
      fi
    done
    # migration done 
    if [[ "$created" == "0" ]]; then
         printf "\n>>> No Document to copy.\n"
    else
      total=$(jq -r ".task.status.total" <<< "$response")
      tookMS=$(jq -r ".response.took" <<< "$response")
      message=">>> Migration of $1: ${created} documents in ${tookMS}ms ($(( 1000*created/(tookMS+1) )) documents/s). Task ID: $2"
      echo -e "\n${message}"
    fi
}

function publishMonitoringSource() {
    ms='{
  "id": "_bai4s",
  "name": "_bai4s",
  "monitoringSources": [
    {
      "id": "Workflow (BPEL)",
      "name": "Workflow (BPEL)",
      "elasticsearchIndex": "icp4ba-bai-bawadv-summaries-ibm-bai",
      "fields": [
        {
          "field": "processTemplateId",
          "labelField": "processTemplateName"
        }
      ]
    },
    {
      "id": "Workflow (BPMN)",
      "name": "Workflow (BPMN)",
      "elasticsearchIndex": "icp4ba-bai-process-summaries-ibm-bai",
      "fields": [
        {
          "field": "processId",
          "labelField": "processName"
        },
        {
          "field": "processVersionId",
          "labelField": "processSnapshotName"
        }
      ]
    },
    {
      "id": "Workflow (Case)",
      "name": "Workflow (Case)",
      "elasticsearchIndex": "icp4ba-bai-case-summaries-ibm-bai",
      "fields": [
        {
          "field": "solution-name.keyword"
        }
      ]
    },
    {
      "id": "Workflow (Case) - Timeseries",
      "name": "Workflow (Case) - Timeseries",
      "elasticsearchIndex": "icp4ba-bai-case-timeseries-ibm-bai",
      "fields": [
        {
          "field": "solution-name.keyword"
        }
      ]
    },
    {
      "id": "Decisions (ODM)",
      "name": "Decisions (ODM)",
      "elasticsearchIndex": "icp4ba-bai-odm-timeseries-ibm-bai",
      "fields": [
        {
          "field": "rulesetPath"
        }
      ]
    },
    {
      "id": "Content",
      "name": "Content",
      "elasticsearchIndex": "icp4ba-bai-content-timeseries-ibm-bai",
      "fields": [
        {
          "field": "objectStoreId",
          "labelField": "objectStoreName"
        }
      ]
    }
  ]
    }'

   echo "Write Monitoring Sources."
   curlPOST "icp4ba-bai-store-monitoring-sources/_doc" "$ms"
   echo
}

# "macros" to simplify code reading
function curlPUT() {
     curl -s -X PUT -u "${OPENSEARCH_USERNAME:?}:${OPENSEARCH_PASSWORD:?}" --insecure --url "${OPENSEARCH_URL:?}/$1" -H 'Content-Type: application/json' -d "$2"
}
function curlPOST() {
     curl -s -X POST -u "${OPENSEARCH_USERNAME:?}:${OPENSEARCH_PASSWORD:?}" --insecure --url "${OPENSEARCH_URL:?}/$1" -H 'Content-Type: application/json' -d "$2"
}
function curlGET() {
     curl -s -X GET -u "${OPENSEARCH_USERNAME:?}:${OPENSEARCH_PASSWORD:?}" --insecure --url "${OPENSEARCH_URL:?}/$1" -H 'Content-Type: application/json'
}
function curlDEL() {
     curl -s -X DELETE -u "${OPENSEARCH_USERNAME:?}:${OPENSEARCH_PASSWORD:?}" --insecure --url "${OPENSEARCH_URL:?}/$1" 
}
function curlHEAD() {
     # used to check whether an index exists
     # prints 404 or 200
     curl -s --head  -w '%{response_code}\n' -o /dev/null -u "${OPENSEARCH_USERNAME:?}:${OPENSEARCH_PASSWORD:?}" --insecure --url "${OPENSEARCH_URL:?}/$1" 
}


function happy-path() {
    # in ideal conditions this full pipeline does the job.
    BAI4S_INSTALL_DIR=$(pwd)
    initBAI4Senv
    # patch and restart BAI4S, do it once.
    patchBAI4S
    # wait a few minutes ES is up and running
    makeSnapshot
    # if want to redo the snapshot, call deleteSnapshot

    # transfer snapshot to OS. Should be done once.
    getOScredentials
    copySnapshotToOS 

    # the following commands can be executed from any machine with access to OS
    # if you changed of machine, call getOScredentials
    # restore indices from snapshot
    restoreSnapshotOnOS

    # fix indices on OS
    transformIndices
    # add monitoring source, only if it was lost in the process
    # publishMonitoringSource
}
