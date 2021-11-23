#!/bin/bash

set -o errexit
set -x

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
ovn_branch="${OVN_BRANCH:-main}"
ovn_k8s_repo="${OVN_K8S_REPO:-https://github.com/ovn-org/ovn-kubernetes.git}"
ovn_k8s_branch="${OVN_K8S_BRANCH:-master}"

os_image=${OS_IMAGE:-"registry.fedoraproject.org/fedora:32"}

function die() {
    echo $1
    exit 1
}

function generate() {
    # Make sure rundir exists.
    mkdir -p ${rundir}

    install_venv
    pushd ${rundir}
    source ${ovn_kh_venv}/bin/activate
    PYTHONPATH=${topdir}/utils python ${ovn_khosts_generate} ${phys_deployment} ${rundir} > ${hosts_file}
    # PYTHONPATH=${topdir}/utils ${ovn_fmn_docker} ${phys_deployment} > ${docker_daemon_file}
    # PYTHONPATH=${topdir}/utils ${ovn_fmn_podman} ${phys_deployment} > ${podman_registry_file}
    deactivate
}

function clone_component() {
    local comp_name=$1
    local comp_repo=$2
    local comp_branch=$3
    local clonedir=$4

    pushd ${clonedir}
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
    pushd ${rundir}
    mkdir -p ovn-k8s-image-bin
    pushd ovn-k8s-image-bin
    clone_component ovn-kubernetes ${ovn_k8s_repo} ${ovn_k8s_branch} ${rundir}/ovn-k8s-image-bin
    clone_component ovs ${ovs_repo} ${ovs_branch} ${rundir}/ovn-k8s-image-bin
    clone_component ovn ${ovn_repo} ${ovn_branch} ${rundir}/ovn-k8s-image-bin
    popd

    cat > ovn-k8s-image-bin/build_ovn_k8s.sh << EOF
#!/bin/bash

set -x

dnf upgrade -y && dnf install --best --refresh -y --setopt=tsflags=nodocs \
	python3-pyyaml bind-utils procps-ng openssl numactl-libs firewalld-filesystem \
        libpcap hostname kubernetes-client python3-openvswitch python3-pyOpenSSL  \
        iptables iproute iputils strace socat\
	@'Development Tools' rpm-build dnf-plugins-core kmod && \
	dnf clean all && rm -rf /var/cache/dnf/*

dnf install -y autoconf automake libtool make openssl-devel wget
dnf install -y checkpolicy desktop-file-utils gcc-c++ groff libcap-ng-devel \
    python3-devel  selinux-policy-devel unbound unbound-devel python3-sphinx
echo "Building OVS"

pushd /root/sources/ovs
./boot.sh
./configure --prefix=/usr --localstatedir=/var --sysconfdir=/etc --enable-ssl
make rpm-fedora
rm -rf /root/sources/bin
mkdir -p /root/sources/bin
cp rpm/rpmbuild/RPMS/x86_64/openvswitch-2*.rpm /root/sources/bin/
popd

pushd /root/sources/ovn
./boot.sh
./configure --prefix=/usr --localstatedir=/var --sysconfdir=/etc --with-ovs-source=/root/sources/ovs
make rpm-fedora
cp rpm/rpmbuild/RPMS/x86_64/ovn*.rpm /root/sources/bin/
rm -f /root/sources/bin/*debug*.rpm
rm -f /root/sources/bin/ovn-docker*.rpm
rm -f /root/sources/bin/ovn-vtep*.rpm
popd

# Install golang
wget https://golang.org/dl/go1.17.1.linux-amd64.tar.gz
rm -rf /usr/local/go && tar -C /usr/local -xzf go1.17.1.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
go version

pushd /root/sources/ovn-kubernetes/go-controller
make
cp _output/go/bin/* /root/sources/bin/
cp ../dist/images/ovnkube.sh /root/sources/bin/
cp ../dist/images/ovndb-raft-functions.sh /root/sources/bin/
cp -rf ../dist/images/iptables-scripts /root/sources/bin/
EOF

    chmod 0755 ovn-k8s-image-bin/build_ovn_k8s.sh
    docker rm -f ovn_image_build || :
    docker run --privileged --network=host -v ${rundir}/ovn-k8s-image-bin:/root/sources --name ovn_image_build -it ${os_image} /root/sources/build_ovn_k8s.sh
    docker rm -f ovn_image_build
    popd

    pushd ${rundir}/ovn-k8s-image-bin/bin
    cp ${ovn_k8s_docker_file} .
    echo "-- Building OVN K8s docker image"
    docker build -t ovn-daemonset-f:dev  --build-arg OS_IMAGE=${os_image} -f ${ovn_k8s_docker_file} .
    docker tag ovn-daemonset-f:dev localhost:5000/ovn-daemonset-f:dev
    docker push localhost:5000/ovn-daemonset-f:dev
}

function setup_kind() {
    echo "-- Setting up kind on the nodes"
    ansible-playbook ${ovn_kh_playbooks}/pull-ovn-k8s-image.yml -i ${hosts_file}
    ansible-playbook ${ovn_kh_playbooks}/setup-kind.yml -i ${hosts_file}
}

function install() {
    pushd ${rundir}
    install_deps
    configure_docker
    popd
}

function setup() {
    pushd ${rundir}
    install_ovn_underlay
    build_ovn_k8s_image
    setup_kind
    create_ovn_underlay_resources
    popd
}

function deploy() {
    echo "--Starting OVN services on kind nodes"
    ansible-playbook ${ovn_kh_playbooks}/start-ovn-underlay.yml -i ${hosts_file}

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
    ansible-playbook ${ovn_kh_playbooks}/stop-ovn-underlay.yml -i ${hosts_file}
}

function run() {
    echo "run"
}

function usage() {
    die "Usage: $0 install|setup|init|deploy|cleanup|run <scenario> <out-dir>"
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
    "setup")
        ;&
    "init")
        ;&
    "deploy")
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
    "setup")
        setup
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
        run
        ;;
    *)
        usage $0
        ;;
    esac

exit 0
