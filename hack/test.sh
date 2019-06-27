set -xeufo pipefail

SCRIPT_PATH="$(dirname "$(readlink -f "$0")")"
BUCKET='minio/logs'
SHA="$(git rev-parse --short HEAD)"
NAMESPACE="logging-operator-${SHA}"

function cleanup()
{
    (
        helm delete --purge "logging-operator-fluent-${SHA}";
        helm delete --purge "logging-operator-${SHA}";
        kubectl delete namespace "${NAMESPACE}";
        kubectl delete sa logging logging-fluentd;
        kubectl delete crd fluentbits.logging.banzaicloud.com fluentds.logging.banzaicloud.com;
        kubectl delete -n "${NAMESPACE}" service "logging-operator-${SHA}";
        mc rb  --force minio/logs-${SHA}
    ) || true
}
trap cleanup EXIT

function main()
{
    ensure_namespace
    mc config host add minio \
        'http://minio.jx.svc.cluster.local:9000' \
        'minio_access_key' \
        'minio_secret_key'
    mc mb --region='test_region' minio/logs-${SHA}
    prepare_output_config

    add_repo
    helm_deploy_logging_operator
    helm_deploy_logging_operator_fluent

    apply_s3_output
    wait_for_log_files 300
    print_logs
}

function ensure_namespace()
{
    if ! kubectl get namespace | grep -q "${NAMESPACE}"; then
        kubectl create namespace "${NAMESPACE}" || true
    fi
}

function add_repo()
{
    helm repo add banzaicloud-stable https://kubernetes-charts.banzaicloud.com
    helm repo update
}

function prepare_output_config()
{
    sed -i "s/###BUCKET###/logs-${SHA}/" ${SCRIPT_PATH}/test-s3-output.yaml
}

function helm_deploy_logging_operator()
{
    helm install \
        --wait \
        --name "logging-operator-${SHA}" \
        --namespace "${NAMESPACE}" \
        --set image.tag=local \
        --set image.repository=161831738826.dkr.ecr.us-east-1.amazonaws.com/banzaicloud/logging-operator \
        ${SCRIPT_PATH}/../charts/logging-operator
}

function helm_deploy_logging_operator_fluent()
{
    helm install \
        --wait \
        --name "logging-operator-fluent-${SHA}" \
        --namespace "${NAMESPACE}" \
        ${SCRIPT_PATH}/../charts/logging-operator-fluent
}


function apply_s3_output()
{
    kubectl apply -n "${NAMESPACE}" -f "${SCRIPT_PATH}/test-s3-output.yaml"
}

function wait_for_log_files()
{
    local deadline="$(( $(date +%s) + $1 ))"

    echo 'Waiting for log files...'
    while [ $(date +%s) -lt ${deadline} ]; do
        if [ $(count_log_files) -gt 0 ]; then
            return
        fi
        sleep 5
    done

    echo 'Cannot find any log files within timeout'
    exit 1
}

function count_log_files()
{
    get_log_files |  wc -l
}

function get_log_files()
{
    mc find "${BUCKET}"  --name '*.gz'
}

function print_logs()
{
    mc find "${BUCKET}" --name '*.gz' -exec 'mc cat {}' | gzip -d
}

main "$@"
