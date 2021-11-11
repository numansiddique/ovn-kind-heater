#!/usr/bin/env python

import logging
import sys
import netaddr
import yaml
import importlib

from collections import namedtuple
from ovn_context import Context
from ovn_sandbox import PhysicalNode
from ovn_kh_workload import WorkerNode


FORMAT = '%(asctime)s | %(name)-12s |%(levelname)s| %(message)s'
logging.basicConfig(stream=sys.stdout, level=logging.INFO, format=FORMAT)


GlobalCfg = namedtuple('GlobalCfg', ['log_cmds', 'cleanup'])

ClusterBringupCfg = namedtuple('ClusterBringupCfg',
                               ['n_pods_per_node'])


def calculate_default_node_remotes(net, clustered, n_relays, enable_ssl):
    ip_gen = net.iter_hosts()
    if n_relays > 0:
        skip = 3 if clustered else 1
        for _ in range(0, skip):
            next(ip_gen)
        ip_range = range(0, n_relays)
    else:
        ip_range = range(0, 3 if clustered else 1)
    if enable_ssl:
        remotes = ["ssl:" + str(next(ip_gen)) + ":6642" for _ in ip_range]
    else:
        remotes = ["tcp:" + str(next(ip_gen)) + ":6642" for _ in ip_range]
    return ','.join(remotes)


def usage(name):
    print(f'''
{name} PHYSICAL_DEPLOYMENT TEST_CONF
where PHYSICAL_DEPLOYMENT is the YAML file defining the deployment.
where TEST_CONF is the YAML file defining the test parameters.
''', file=sys.stderr)


def read_physical_deployment(deployment):
    with open(deployment, 'r') as yaml_file:
        dep = yaml.safe_load(yaml_file)

        central_dep = dep['central-node']
        central_node = PhysicalNode(
            central_dep.get('name', 'localhost'), False)
        worker_nodes = [
            PhysicalNode(worker, True)
            for worker in dep['worker-nodes']
        ]
        return central_node, worker_nodes

RESERVED = [
    'global',
    'cluster',
    'base_cluster_bringup',
    'ext_cmd',
]


def configure_tests(yaml, central_node, worker_nodes):
    tests = []
    for section, cfg in yaml.items():
        if section in RESERVED:
            continue

        mod = importlib.import_module(f'tests.{section}')
        class_name = ''.join(s.title() for s in section.split('_'))
        cls = getattr(mod, class_name)
        tests.append(cls(yaml, central_node, worker_nodes))
    return tests


def _get_worker_mac(worker_id):
    base_mac = "ae:01:00:00:"
    x = int((worker_id + 5) / 255)
    y = (worker_id + 5) % 255
    xstr = hex(x).split('x')[-1]
    if len(xstr) == 1:
        xstr = "0" + xstr
    ystr = hex(y).split('x')[-1]
    if len(ystr) == 1:
        ystr = "0" + ystr
    return "ae:01:00:00:" + xstr + ":" + ystr


def create_worker_nodes(workers, central, n_workers):
    kind_network = netaddr.IPNetwork('10.82.0.0/16')
    worker_ip = kind_network.ip + 6
    nb_remote = "tcp:" + central.hostname + ":6641"
    worker_nodes = [
        WorkerNode(workers[i % len(workers)], f'ovn-worker{i + 3}',
                   str(worker_ip + i), _get_worker_mac(i),
                   nb_remote, "kindest/node:v1.20.0",
                   "localhost/ovn-daemonset-f:dev")
        for i in range(n_workers)
    ]
    return worker_nodes

def configure_worker_nodes(worker_nodes):
    with Context("base_cluster_bringup", len(worker_nodes)) as ctx:
        for w in worker_nodes:
            w.configure()


if __name__ == '__main__':
    if len(sys.argv) != 3:
        usage(sys.argv[0])
        sys.exit(1)

    central, workers = read_physical_deployment(sys.argv[1])
    print('central nodes = ' + str(central))
    print('worker nodes = ' + str(workers))
    worker_nodes = create_worker_nodes(workers, central, int(sys.argv[2]))
    configure_worker_nodes(worker_nodes)
    sys.exit(0)
