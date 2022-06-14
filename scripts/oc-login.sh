#!/usr/bin/env bash

INPUT=$(tee)

BIN_DIR=$(echo "${INPUT}" | grep "bin_dir" | sed -E 's/.*"bin_dir": ?"([^"]*)".*/\1/g')

if [[ -n "${BIN_DIR}" ]]; then
  export PATH="${BIN_DIR}:${PATH}"
fi

if ! command -v jq 1> /dev/null 2> /dev/null; then
  echo "jq cli not found" >&2
  echo "bin_dir: ${BIN_DIR}" >&2
  ls -l "${BIN_DIR}" >&2
  exit 1
fi

if ! command -v oc 1> /dev/null 2> /dev/null; then
  echo "oc cli not found" >&2
  echo "bin_dir: ${BIN_DIR}" >&2
  ls -l "${BIN_DIR}" >&2
  exit 1
fi


SERVER=$(echo "${INPUT}" | jq -r '.serverUrl')
USERNAME=$(echo "${INPUT}" | jq -r '.username')
PASSWORD=$(echo "${INPUT}" | jq -r '.password')
KUBE_CONFIG_DIR=$(echo "${INPUT}" | jq -r '.kube_config')
TMP_DIR=$(echo "${INPUT}" | jq -r '.tmp_dir')
CLUSTER_STATUS=$(echo "${INPUT}" | jq -r '.clusterStatus')

TOKEN=""

if [[ "${CLUSTER_STATUS}" == "error" ]]; then
  echo "{\"status\":  \"error\", \"message\": \"Cluster is in error state to login. Please verify cluster config\", \"kube_config\": \"\", \"token\":\"\"}"
  exit 1
fi

KUBE_CONFIG="${KUBE_CONFIG_DIR}/config"
export KUBECONFIG=${KUBE_CONFIG}
#touch "${KUBE_CONFIG_DIR}/config"    

if [[ "${CLUSTER_STATUS}" == "ready" ]]; then        
    if [[ -z "${USERNAME}" ]] && [[ -z "${PASSWORD}" ]] ; then
      echo "{\"status\": \"na\", \"message\": \"The username  ${USERNAME} and password ${PASSWORD}  must be provided to log into ocp\", \"kube_config\": \"\", \"token\":\"\"}"
      exit 0
    fi  
    if ! oc login ${SERVER} --username ${USERNAME} --password ${PASSWORD} 1> /dev/null; then      
        echo "{\"status\": \"error\", \"message\": \"Unable to login to ocp with given credentials\", \"kube_config\": \"\", \"serverUrl\":\"${SERVER}\", \"token\":\"\"}"
        exit 0
    else
        TOKEN=$(cat ${KUBE_CONFIG}  | grep "token:" |  tail -1 |  awk  '{print $2}')
        
        echo "{\"status\": \"success\", \"message\": \"success\", \"kube_config\": \"${KUBE_CONFIG}\", \"serverUrl\":\"${SERVER}\", \"token\":\"${TOKEN}\"}"
        exit 0
    fi
else
    echo "{\"status\": \"error\", \"message\":\"Error: Cluster is not ready to login. Please verify cluster config\", \"kube_config\": \"\", \"token\":\"\"}"
    exit 0
fi  