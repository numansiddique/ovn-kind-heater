#!/bin/bash

set -o errexit

topdir=$(pwd)
rundir=${topdir}/runtime
ovn_kind_heater_utils=${topdir}/ovn-kind-heater-utils
ovn_kh_playbooks=${ovn_kind_heater_utils}/playbooks
ovn_k8s_docker_file=${ovn_kind_heater_utils}/scripts/Dockerfile.ovnk8s.fedora
hosts_file=${rundir}/hosts
deployment_dir=${topdir}/physical-deployments
phys_deployment="${PHYS_DEPLOYMENT:-${deployment_dir}/physical-deployment.yml}"
installer_log_file=${rundir}/installer-log
ovn_kh_venv=venv
ovn_kh_tester=${topdir}/ovn-kind-heater-tester
ovn_khosts_generate=${ovn_kind_heater_utils}/generate-hosts.py
n_k8s_workers="${NUM_K8S_WORKERS:-5}"
ovn_kind_heater_log_file=test-log

# OVS/OVN env vars
ovs_repo="${OVS_REPO:-https://github.com/openvswitch/ovs.git}"
ovs_branch="${OVS_BRANCH:-master}"
ovn_repo="${OVN_REPO:-https://github.com/ovn-org/ovn.git}"
ovn_branch="${OVN_BRANCH:-master}"
ovn_k8s_repo="${OVN_K8S_REPO:-https://github.com/ovn-org/ovn-kubernetes.git}"
ovn_k8s_branch="${OVN_K8S_BRANCH:-master}"

function die() {
    echo $1
    exit 1
}

function generate() {
    # Make sure rundir exists.
    mkdir -p ${rundir}

    PYTHONPATH=${topdir}/utils ${ovn_khosts_generate} ${phys_deployment} ${rundir} > ${hosts_file}
    # PYTHONPATH=${topdir}/utils ${ovn_fmn_docker} ${phys_deployment} > ${docker_daemon_file}
    # PYTHONPATH=${topdir}/utils ${ovn_fmn_podman} ${phys_deployment} > ${podman_registry_file}
}

function clone_component() {
    local comp_name=$1
    local comp_repo=$2
    local comp_branch=$3

    pushd ${rundir}
    local comp_exists="0"
    if [ -d ${comp_name} ]; then
        pushd ${comp_name}
        local remote=$(git config --get remote.origin.url)
        if [ "${remote}" = "${comp_repo}" ]; then
            git fetch origin

            if $(git show-ref --verify refs/tags/${comp_branch} &> /dev/null); then
                local branch_diff=$(git diff ${comp_branch} HEAD --stat | wc -l)
            else
                local branch_diff=$(git diff origin/${comp_branch} HEAD --stat | wc -l)
            fi
            if [ "${branch_diff}" = "0" ]; then
                comp_exists="1"
            fi
        fi
        popd
    fi

    if [ ${comp_exists} = "1" ]; then
        echo "-- Component ${comp_name} already installed"
    else
        rm -rf ${comp_name}
        echo "-- Cloning ${comp_name} from ${comp_repo} at revision ${comp_branch}"
        git clone ${comp_repo} ${comp_name}
        pushd ${comp_name}
        git checkout ${comp_branch}
        popd
    fi
    popd
}

function install_deps() {
    echo "-- Installing dependencies on all nodes"
    ansible-playbook ${ovn_kh_playbooks}/install-dependencies.yml -i ${hosts_file}

    echo "-- Installing local dependencies"
    if yum install docker-ce --nobest -y || yum install -y docker
    then
        systemctl start docker
    else
        yum install -y podman podman-docker
    fi
    yum install redhat-lsb-core datamash \
        python3-pip python3-virtualenv python3 python3-devel python-virtualenv \
        --skip-broken -y
    [ -e /usr/bin/pip ] || ln -sf /usr/bin/pip3 /usr/bin/pip

    containers=$(docker ps --filter='name=(ovn|registry)' \
                        | grep -v "CONTAINER ID" | awk '{print $1}')
    for container_name in $containers
    do
        docker stop $container_name
        docker rm $container_name
    done
    [ -d /var/lib/registry ] || mkdir /var/lib/registry -p
    docker run --privileged -d --name registry -p 5000:5000 \
          -v /var/lib/registry:/var/lib/registry --restart=always docker.io/library/registry:2
        cp /etc/containers/registries.conf /etc/containers/registries.conf.bak
        cat > /etc/containers/registries.conf << EOF
[registries.search]
registries = ['registry.access.redhat.com', 'registry.redhat.io']
[registries.insecure]
registries = ['localhost:5000']
[registries.block]
registries = []
EOF
}

function install_venv() {
    pushd ${rundir}
    python3 -m virtualenv ${ovn_kh_venv}
    source ${ovn_kh_venv}/bin/activate
    pip install -r ${ovn_kh_tester}/requirements.txt
    deactivate
    popd
}

function configure_docker() {
    echo "-- Configuring local registry on tester nodes"
    if which podman
    then
        echo "-- Configuring podman local registry on all nodes"
        ansible-playbook ${ovn_kh_playbooks}/configure-podman-registry.yml -i ${hosts_file}
    else
        echo "-- Configuring docker local registry on all nodes"
        ansible-playbook ${ovn_kh_playbooks}/configure-docker-registry.yml -i ${hosts_file}
    fi
}

function install_ovn_underlay() {
    echo "-- Installing OVN underlay on all nodes"
    ansible-playbook ${ovn_kh_playbooks}/install-ovn-underlay.yml -i ${hosts_file}
}

function create_ovn_underlay_resources() {
    echo "-- Creating OVN underlay resources"
    ansible-playbook ${ovn_kh_playbooks}/create-ovn-underlay-res.yml -i ${hosts_file}
}

function build_ovn_k8s_image() {
    echo "-- Building OVN K8s image"
    clone_component ovn-kubernetes ${ovn_k8s_repo} ${ovn_k8s_branch}
    pushd ${rundir}/ovn-kubernetes
    pushd go-controller
    echo "-- Compiling OVN K8s"
    make
    popd
    pushd dist/images
    # Find all built executables, but ignore the 'windows' directory if it exists
    echo "-- Copying OVN K8s binaries"
    find ../../go-controller/_output/go/bin/ -maxdepth 1 -type f -exec cp -f {} . \;
    echo "ref: $(git rev-parse  --symbolic-full-name HEAD)  commit: $(git rev-parse  HEAD)" > git_info
    cp ${ovn_k8s_docker_file} .
    echo "-- Building OVN K8s docker image"
    docker build -t ovn-daemonset-f:dev  --build-arg OVN_REPO=${ovn_repo} --build-arg OVN_BRANCH=${ovn_branch} --build-arg OVS_REPO=${ovs_repo} --build-arg OVS_BRANCH=${ovs_branch} -f ${ovn_k8s_docker_file} .
    docker tag ovn-daemonset-f:dev localhost:5000/ovn-daemonset-f:dev
    docker push localhost:5000/ovn-daemonset-f:dev
}

function setup_kind() {
    ansible-playbook ${ovn_kh_playbooks}/pull-ovn-k8s-image.yml -i ${hosts_file}
    ansible-playbook ${ovn_kh_playbooks}/setup-kind.yml -i ${hosts_file}
}

function install() {
    pushd ${rundir}
    install_deps
    install_venv
    #configure_docker
    install_ovn_underlay
    build_ovn_k8s_image
    setup_kind
    create_ovn_underlay_resources
    popd
}

function deploy() {
    echo "--Deploying base k8s cluster on central node"
    ansible-playbook ${ovn_kh_playbooks}/deploy-ovn-k8s-kind.yml -i ${hosts_file}

    source ${rundir}/${ovn_kh_venv}/bin/activate
    #pushd ${out_dir}
    echo "-- Adding k8s worker nodes"
    python -u ${ovn_kh_tester}/ovn_kh_tester.py $phys_deployment ${n_k8s_workers} 2>&1 | tee ${ovn_kind_heater_log_file}

    echo "-- Waiting for the nodes to be ready"
    ansible-playbook ${ovn_kh_playbooks}/check-ovn-k8s-kind-ready.yml -i ${hosts_file}
}

function cleanup_kind() {
    ansible-playbook ${ovn_kh_playbooks}/cleanup-kind.yml -i ${hosts_file}
}

function run() {
    echo "run"
}

function usage() {
    die "Usage: $0 install|generate|init|run <scenario> <out-dir>"
}

do_lockfile=/tmp/do-kind.sh.lock

function take_lock() {
    exec 42>${do_lockfile} || die "Failed setting FD for ${do_lockfile}"
    flock -n 42 || die "Error: ovn-heater ($1) already running"
}

case "${1:-"usage"}" in
    "install")
        ;&
    "generate")
        ;&
    "init")
        ;&
    "run")
        take_lock $0
        trap "rm -f ${do_lockfile}" EXIT
        ;;
    esac

case "${1:-"usage"}" in
    "install")
        generate

        # Store current environment variables.
        (
            echo "Environment:"
            echo "============"
            env
            echo
        ) > ${installer_log_file}

        # Run installer and store logs.
        (
            echo "Installer logs:"
            echo "==============="
        ) >> ${installer_log_file}
        install 2>&1 | tee -a ${installer_log_file}
        ;;
    "generate")
        generate
        ;;
    "init")
        cleanup_kind
        ;;
    "deploy")
        deploy
        ;;
    "cleanup")
        cleanup_kind
        ;;
    "run")
        ;;
    
    *)
        usage $0
        ;;
    esac

exit 0
