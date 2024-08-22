#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname $(readlink -f ${BASH_SOURCE[0]}))" &>/dev/null && pwd)"

source ${ROOT_DIR}/config.sh

# TODO verify config

USER=`whoami`
STORE_PREFIX="${USER}-${CLUSTER_NAME}"

# A dir to save cluster data
CLUSTER_ROOT=${ROOT_DIR}/${CLUSTER_NAME}

# A dir to save pkgs
DORIS_PKG_DIR=${CLUSTER_ROOT}/pkg

# A dir to save FE config, data, log
FE_HOME=${CLUSTER_ROOT}/fe

# A dir to save BE config, data, log
BE_HOME=${CLUSTER_ROOT}/be

# A dir to save BROKER config, data, log
BROKER_HOME=${CLUSTER_ROOT}/fs_broker

# A dir to save download binaries
DOWNLOAD_BINARY_DIR=pkgs

function fe_port() {
    local i="$1"
    local name="$2"
    local config=${FE_CONFIG[$i]}
    ${config} "${FE_HOME}/$i" "none" | \
        grep -E "^${name}" | \
        tr -d ' ' |
        cut -d'=' -f2
}

function fe_edit_log_port() {
    fe_port $1 edit_log_port
}

function fe_query_port() {
    fe_port $1 query_port
}

function be_port() {
    local i="$1"
    local name="$2"
    local config=${BE_CONFIG[$i]}
    ${config} "${BE_HOME}/$i" "none" | \
        grep ${name} | \
        tr -d ' ' |
        cut -d'=' -f2
}

function be_heartbeat_port() {
    be_port $1 heartbeat_service_port
}

function add_fe_cluster() {
    local NUM_FE=${#FE_CONFIG[@]}
    for ((i=1;i<NUM_FE;i++)); do
        echo "ALTER SYSTEM ADD FOLLOWER \"127.0.0.1:$(fe_edit_log_port $i)\";" |
            mysql -uroot -h127.0.0.1 -P$(fe_query_port 0) 2>/dev/null || true
    done
}

function add_be_cluster() {
    local NUM_BE=${#BE_CONFIG[@]}

    for ((i=0;i<NUM_BE;i++)); do
        echo "ALTER SYSTEM ADD BACKEND \"127.0.0.1:$(be_heartbeat_port $i)\"" |
            mysql -uroot -h127.0.0.1 -P$(fe_query_port 0) 2>/dev/null || true
    done
}

function broker_ipc_port() {
    local i="$1"
    local config=${BROKER_CONFIG[$i]}
    ${config} "${BROKER_HOME}/$i" | \
        grep "broker_ipc_port" | \
        tr -d ' ' |
        cut -d'=' -f2
}

function add_broker_cluster() {
    local NUM_BROKER=${#BROKER_CONFIG[@]}

    for ((i=0;i<NUM_BROKER;i++)); do
        echo "ALTER SYSTEM ADD BROKER broker_$i \"127.0.0.1:$(broker_ipc_port $i)\"" |
            mysql -uroot -h127.0.0.1 -P$(fe_query_port 0) 2>/dev/null || true
    done
}

function init_cluster() {
    local cnt=0
    local query_port=$(fe_query_port 0)
    while ! echo "" | mysql -uroot -h127.0.0.1 -P${query_port} 2>/dev/null; do
        sleep 1
        cnt=$(($cnt + 1))
        if [[ $cnt == 30 ]]; then
            echo "The fe query port: ${query_port} is not listening"
            exit -1
        fi
    done

    add_fe_cluster
    add_be_cluster
    add_broker_cluster
}

function deploy_fe() {
    local skip_pkg="$1"
    local skip_config="$2"

    # update package
    if [ ! -d ${DORIS_PKG_DIR}/fe/lib ]; then
        mkdir -p ${DORIS_PKG_DIR}/fe
        cp -r ${FE_OUTPUT_DIR}/* ${DORIS_PKG_DIR}/fe/
    elif [[ $skip_pkg != "true" ]]; then
        rm -rf ${DORIS_PKG_DIR}/fe
        mkdir -p ${DORIS_PKG_DIR}/fe
        cp -rf ${FE_OUTPUT_DIR}/* ${DORIS_PKG_DIR}/fe/
    fi

    local NUM_FE=${#FE_CONFIG[@]}
    for ((i=0;i<NUM_FE;i++)); do
        DORIS_HOME=${FE_HOME}/$i
        config=${FE_CONFIG[@]}

        mkdir -p ${DORIS_HOME}/{conf,log,doris-meta}
        cp -r ${DORIS_PKG_DIR}/fe/bin ${DORIS_HOME}/
        ln -sf ${DORIS_PKG_DIR}/fe/lib ${DORIS_HOME}/lib

        if [ ! -f ${DORIS_HOME}/conf/fe_custom.conf ] || \
            [[ ${skip_config} != "true" ]]; then
            cp -r ${DORIS_PKG_DIR}/fe/conf ${DORIS_HOME}/
            cat >${DORIS_HOME}/conf/fe_custom.conf <<EOF
$(eval ${config})
EOF
        fi
    done
}

function start_fe() {
    export JAVA_HOME=${JAVA_HOME}

    local NUM_FE=${#FE_CONFIG[@]}
    for ((i=0;i<NUM_FE;i++)); do
        if [ ! -d ${FE_HOME}/$i ]; then
            echo "the fe home dir ${FE_HOME}/$i is not exists, please deploy it"
            return
        fi
        if [[ $i == 0 ]]; then
            cd ${FE_HOME}/$i && \
                DORIS_HOME=${FE_HOME}/$i ./bin/start_fe.sh --daemon
        else
            cd ${FE_HOME}/$i && \
                DORIS_HOME=${FE_HOME}/$i ./bin/start_fe.sh --daemon \
                    --helper 127.0.0.1:$(fe_edit_log_port 0)
        fi
    done
}

function stop_fe() {
    local NUM_FE=${#FE_CONFIG[@]}
    for ((i=0;i<NUM_FE;i++)); do
        if [ -d ${FE_HOME}/$i ]; then
            cd ${FE_HOME}/$i && \
                DORIS_HOME=${FE_HOME}/$i ./bin/stop_fe.sh --daemon
        fi
    done
}

function clean_fe() {
    if ps -ef | grep java | grep ${CLUSTER_NAME} >/dev/null; then
        echo "Please stop fe first"
        exit 1
    fi

    rm -rf ${FE_HOME}
}

function deploy_be() {
    local skip_pkg="$1"
    local skip_config="$2"

    # update package
    if [ ! -d ${DORIS_PKG_DIR}/be/lib ]; then
        mkdir -p ${DORIS_PKG_DIR}/be
        cp -r ${BE_OUTPUT_DIR}/* ${DORIS_PKG_DIR}/be/
    elif [[ $skip_pkg != "true" ]]; then
        rm -rf ${DORIS_PKG_DIR}/be
        mkdir -p ${DORIS_PKG_DIR}/be
        cp -rf ${BE_OUTPUT_DIR}/* ${DORIS_PKG_DIR}/be/
    fi

    local NUM_BE=${#BE_CONFIG[@]}
    for ((i=0;i<NUM_BE;i++)); do
        DORIS_HOME=${BE_HOME}/$i
        config=${BE_CONFIG[$i]}

        mkdir -p ${DORIS_HOME}/{storage,conf,log}
        cp -r ${DORIS_PKG_DIR}/be/bin ${DORIS_HOME}/
        ln -sf ${DORIS_PKG_DIR}/be/lib ${DORIS_HOME}/lib
        ln -sf ${DORIS_PKG_DIR}/be/udf ${DORIS_HOME}/udf

        if [ ! -f ${DORIS_HOME}/conf/be_custom.conf ] || \
            [[ ${skip_config} != "true" ]]; then
            cp -r ${DORIS_PKG_DIR}/be/conf ${DORIS_HOME}/
            cat >${DORIS_HOME}/conf/be_custom.conf <<EOF
$(eval ${config})
EOF
        fi
    done
}

function start_be() {
    export JAVA_HOME=${JAVA_HOME}

    local NUM_BE=${#BE_CONFIG[@]}
    for ((i=0;i<NUM_BE;++i)); do
        if [ ! -d ${BE_HOME}/$i ]; then
            echo "the be home dir ${BE_HOME}/$i is not exists, please deploy it"
            return
        fi
        cd ${BE_HOME}/$i/ && \
            DORIS_HOME=${BE_HOME}/$i ./bin/start_be.sh --daemon
    done
}

function stop_be() {
    local NUM_BE=${#BE_CONFIG[@]}
    for ((i=0;i<NUM_BE;++i)); do
        export DORIS_HOME=${BE_HOME}/$i
        if [ -d ${BE_HOME}/$i ]; then
            cd ${BE_HOME}/$i/ && \
                DORIS_HOME=${BE_HOME}/$i ./bin/stop_be.sh --daemon &
        fi
    done
    wait
}

function clean_be() {
    if ps -ef | grep doris_be | grep ${CLUSTER_NAME} >/dev/null; then
        echo "Please stop be first"
        exit 1
    fi

    rm -rf ${BE_HOME}
}

function deploy_broker() {
    local NUM_BROKER=${#BROKER_CONFIG[@]}
    if [[ ${NUM_BROKER} == 0 ]]; then
        return
    fi

    if [ ! -d ${DORIS_PKG_DIR}/fs_broker/lib ]; then
        mkdir -p ${DORIS_PKG_DIR}/fs_broker
        cp -r ${BROKER_OUTPUT_DIR}/* ${DORIS_PKG_DIR}/fs_broker/
    fi

    for ((i=0;i<NUM_BROKER;i++)); do
        DORIS_HOME=${BROKER_HOME}/$i
        config=${BROKER_CONFIG[$i]}

        mkdir -p ${DORIS_HOME}/{conf,log}
        cp -r ${DORIS_PKG_DIR}/fs_broker/bin ${DORIS_HOME}/
        ln -sf ${DORIS_PKG_DIR}/fs_broker/lib ${DORIS_HOME}/lib

        if [ ! -f ${DORIS_HOME}/conf/apache_hdfs_broker.conf ]; then
            cp -r ${DORIS_PKG_DIR}/fs_broker/conf ${DORIS_HOME}
            if grep 'broker_ipc_port' ${DORIS_HOME}/conf/apache_hdfs_broker.conf >/dev/null; then
                sed -i "s/^broker_ipc_port .*$/broker_ipc_port = $(broker_ipc_port $i)/g" ${DORIS_HOME}/conf/apache_hdfs_broker.conf
            else
                cat >>${DORIS_HOME}/conf/apache_hdfs_broker.conf <<EOF
broker_ipc_port = $(broker_ipc_port $i)
EOF
            fi
        fi
    done

}

function start_broker() {
    export JAVA_HOME=${JAVA_HOME}

    local NUM_BROKER=${#BROKER_CONFIG[@]}
    for ((i=0;i<NUM_BROKER;++i)); do
        if [ ! -d ${BROKER_HOME}/$i ]; then
            echo "the broker home dir ${BROKER_HOME}/$i is not exists, please deploy it"
            return
        fi
        cd ${BROKER_HOME}/$i/ && \
            DORIS_HOME=${BROKER_HOME}/$i ./bin/start_broker.sh --daemon
    done

}

function stop_broker() {
    local NUM_BROKER=${#BROKER_CONFIG[@]}
    for ((i=0;i<NUM_BROKER;++i)); do
        export DORIS_HOME=${BROKER_HOME}/$i
        if [ -d ${BROKER_HOME}/$i ]; then
            cd ${BROKER_HOME}/$i/ && \
                DORIS_HOME=${BROKER_HOME}/$i ./bin/stop_broker.sh --daemon
        fi
    done
}

function clean_broker() {
    if ps -ef | grep apache_hdfs_broker | grep ${CLUSTER_NAME} >/dev/null; then
        echo "Please stop broker first"
        exit 1
    fi

    rm -rf ${BROKER_HOME}
}

function download_binaries() {
    URL=${BINARY_RESOURCE_URL:-""}
    if [[ "$URL" =~ ^https://apache-doris-releases.oss-accelerate.aliyuncs.com/ ]]; then
        PACKAGE_NAME=${URL##*/}
        FILE=${PACKAGE_NAME%%.tar.gz}
        mkdir -p ${DOWNLOAD_BINARY_DIR}/

        FE_OUTPUT_DIR="$(pwd)/${DOWNLOAD_BINARY_DIR}/${FILE}/fe"
        BE_OUTPUT_DIR="$(pwd)/${DOWNLOAD_BINARY_DIR}/${FILE}/be"
        BROKER_OUTPUT_DIR="$(pwd)/${DOWNLOAD_BINARY_DIR}/${FILE}/extensions/apache_hdfs_broker"

        if [ -d ${DOWNLOAD_BINARY_DIR}/${FILE} ]; then
            return
        fi

        rm -rf ${DOWNLOAD_BINARY_DIR}/$PACKAGE_NAME
        rm -rf ${DOWNLOAD_BINARY_DIR}/$FILE
        wget -P ${DOWNLOAD_BINARY_DIR} ${URL}
        pushd ${DOWNLOAD_BINARY_DIR} >/dev/null
        tar zxvf ${PACKAGE_NAME}
        popd >/dev/null
    elif [[ "$URL" =~ ^https://archive.apache.org/dist/doris/ ]]; then
        mkdir -p ${DOWNLOAD_BINARY_DIR}

        # Download FE
        PACKAGE_NAME=${URL##*/}
        FILE=${PACKAGE_NAME%%.tar.gz}

        FE_OUTPUT_DIR="$(pwd)/${DOWNLOAD_BINARY_DIR}/${FILE}"

        if [ ! -d ${DOWNLOAD_BINARY_DIR}/${FILE} ]; then
            rm -rf ${DOWNLOAD_BINARY_DIR}/$PACKAGE_NAME
            rm -rf ${DOWNLOAD_BINARY_DIR}/$FILE
            wget -P ${DOWNLOAD_BINARY_DIR} ${URL}
            pushd ${DOWNLOAD_BINARY_DIR} >/dev/null
            tar zxvf ${PACKAGE_NAME}
            popd >/dev/null
        fi

        # Download BE
        URL=${URL/fe/be}
        URL=${URL/.tar.gz/-x86_64.tar.gz}
        PACKAGE_NAME=${URL##*/}
        FILE=${PACKAGE_NAME%%.tar.gz}

        BE_OUTPUT_DIR="$(pwd)/${DOWNLOAD_BINARY_DIR}/${FILE}"

        if [ ! -d ${DOWNLOAD_BINARY_DIR}/${FILE} ]; then
            rm -rf ${DOWNLOAD_BINARY_DIR}/$PACKAGE_NAME
            rm -rf ${DOWNLOAD_BINARY_DIR}/$FILE
            wget -P ${DOWNLOAD_BINARY_DIR} ${URL}
            pushd ${DOWNLOAD_BINARY_DIR} >/dev/null
            tar zxvf ${PACKAGE_NAME}
            popd >/dev/null
        fi
    fi
}

function deploy() {
    local job="$1"
    local skip_pkg="$2"
    local skip_config="$3"

    download_binaries

    mkdir -p ${DORIS_PKG_DIR}

    if [[ $job =~ ^(all|fe)$ ]]; then
        deploy_fe ${skip_pkg} ${skip_config}
    fi

    if [[ $job =~ ^(all|be)$ ]]; then
        deploy_be ${skip_pkg} ${skip_config}
    fi

    if [[ $job =~ ^(all|broker)$ ]]; then
        deploy_broker
    fi
}

function start() {
    local job="$1"
    local init="$2"

    if [[ $job =~ ^(all|fe)$ ]]; then
        start_fe
    fi

    init_cluster

    if [[ $job =~ ^(all|be)$ ]]; then
        start_be
    fi
     
    if [[ $job =~ ^(all|broker)$ ]]; then
        start_broker
    fi
}

function stop() {
    local job="$1"

    if [[ $job =~ ^(all|fe)$ ]]; then
        stop_fe &
    fi

    if [[ $job =~ ^(all|be)$ ]]; then
        stop_be &
    fi
    if [[ $job =~ ^(all|broker)$ ]]; then
        stop_broker &
    fi
    wait
}

function clean() {
    local job="$1"

    if [[ $job =~ ^(all|fe)$ ]]; then
        clean_fe &
    fi

    if [[ $job =~ ^(all|be)$ ]]; then
        clean_be &
    fi

    if [[ $job =~ ^(all|broker)$ ]]; then
        clean_broker &
    fi
    wait
}

function generate_regression_config() {
    local msg="$1"

    # FE
    export FE_HTTP_ENDPOINT="127.0.0.1:$(fe_port 0 http_port)"
    export FE_QUERY_ENDPOINT="127.0.0.1:$(fe_query_port 0)"
    export FE_THRIFT_ENDPOINT="127.0.0.1:$(fe_port 0 rpc_port)"

    if [[ "${ENABLE_CCR_CLUSTER}" == "true" ]]; then
        export DOWNSTREAM_FE_QUERY_ENDPOINT
        export DOWNSTREAM_FE_THRIFT_ENDPOINT
        export SYNCER_ADDRESS
    else
        export DOWNSTREAM_FE_QUERY_ENDPOINT="${FE_QUERY_ENDPOINT}"
        export DOWNSTREAM_FE_THRIFT_ENDPOINT="${FE_THRIFT_ENDPOINT}"
        export SYNCER_ADDRESS="127.0.0.1:9190"
    fi

    # SUITE/DATA PATH
    export REGRESSION_DATA_PATH
    export REGRESSION_SUITE_PATH
    export REGRESSION_PLUGIN_PATH
    export REGRESSION_SF1_DATA_PATH

    # S3/HDFS
    export ENABLE_HDFS
    export HDFS_FS
    export HDFS_USER
    export BROKER_NAME
    export STORE_AK
    export STORE_SK
    export STORE_ENDPOINT
    export STORE_PROVIDER
    export STORE_REGION
    export STORE_BUCKET

    envsubst <./regression-conf.template >./regression-conf.groovy
    if [[ $msg == "true" ]]; then
        echo 'regression config is generated'
        echo 'usage: ./run-regression-test.sh --conf' `pwd`/regression-conf.groovy
    fi
}

function run_regression() {
    local skip_config="$1"
    shift

    if [ ! -f ./regression-conf.groovy ] || \
        [[ $skip_config != "true" ]]; then
        generate_regression_config false
    fi

    export DORIS_HOME=${DORIS_HOME:-.}
    export JAVA_HOME
    bash -x ${REGRESSION_HOME}/run-regression-test.sh \
        --conf ./regression-conf.groovy $@
}

function usage() {
    echo "Usage: $0 <CMD> [job] [--skip-pkg] [--skip-config] [--init=all]"
    echo -e "\t deploy \t setup cluster env (dir, binary, conf ...)"
    echo -e "\t clean  \t clean cluster data"
    echo -e "\t start  \t start cluster"
    echo -e "\t stop   \t stop all process (fe, be ...)"
    echo -e "\t mysql  \t connect the first FE (FE Master)"
    echo -e "\t config \t generate regression-conf.groovy for regression test"
    echo -e "\t run    \t run regression test"
    echo -e ""
    echo -e "Avail JOB: [fe, be]"
    echo -e ""
    echo -e "Args:"
    echo -e "\t --skip-pkg    \t skip to update binary pkgs during deploy"
    echo -e "\t --skip-config \t skip to update config during deploy"
    echo -e "\t --init        \t skip init step during start"
    echo -e "\t               \t value in (all, skip), default is all"
    echo -e ""
    exit 1
}

function unknown_cmd() {
    local cmd="$1"

    echo "Unknown cmd: ${cmd}\n"
    usage
}

if [[ $# < 1 ]]; then
    usage
fi

cmd="$1"
shift

job="all"
if [[ $# > 0 && "$1" =~ ^(fe|be|broker)$ ]]; then
    job="$1"
    shift
fi

init="all"
skip_pkg="false"
skip_config="false"
while [[ $# > 0 ]]; do
    arg="$1"
    shift
    case $arg in
        --skip-pkg)
            skip_pkg="true"
            ;;
        --skip-config)
            skip_config="true"
            ;;
        --init=all)
            init="all"
            ;;
        --init=skip)
            init="skip"
            ;;
        --)
            break
            ;;
        *)
            unknown_cmd $arg
            ;;
    esac
done

case $cmd in
    deploy)
        deploy "$job" $skip_pkg $skip_config
        ;;
    start)
        start "$job" "${init}"
        ;;
    stop)
        stop "$job"
        ;;
    clean)
        clean "$job"
        ;;
    mysql)
        mysql -uroot -h127.0.0.1 -P$(fe_query_port 0)
        ;;
    config)
        generate_regression_config true
        ;;
    run)
        run_regression $skip_config $@
        ;;
    *)
        unknown_cmd $cmd
        ;;
esac

