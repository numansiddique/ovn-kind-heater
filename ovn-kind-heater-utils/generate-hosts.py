#!/usr/bin/python3

from __future__ import print_function

try:
    from collections.abc import Mapping
except ImportError:
    from collections import Mapping
import yaml
import sys
import socket


def usage(name):
    print("""
{} DEPLOYMENT
where DEPLOYMENT is the YAML file defining the deployment.
""".format(name), file=sys.stderr)

def _get_node_config(config):
    mappings = {}
    if isinstance(config, Mapping):
        host = list(config.keys())[0]
        if config[host]:
            mappings = config[host]
    else:
        host = config
    return host, mappings

def generate_nodes(nodes_config, user, prefix, internal_iface):
    for node_config in nodes_config:
        host, node_config = _get_node_config(node_config)
        internal_iface = node_config.get('internal-iface', internal_iface)
        host_ip = socket.gethostbyname(host)
        generate_worker(host, user, prefix, internal_iface, host_ip)

def generate_central(config, user, prefix, internal_iface, host_ip):
    host = config['name']
    internal_iface = config.get('internal-iface', internal_iface)
    print('{} ansible_user=root become=true internal_iface={} node_name={} ovn_central=true ovn_host_ip={}'.format(
        host, internal_iface, prefix, host_ip
    ))

def generate_worker(host, user, prefix, internal_iface, host_ip):
    print('{} ansible_user=root become=true internal_iface={} node_name={} ovn_host_ip={}'.format(
        host, internal_iface, prefix, host_ip
    ))

def generate(input_file, target):
    with open(input_file, 'r') as yaml_file:
        config = yaml.safe_load(yaml_file)
        user = config.get('user', 'root')
        prefix = config.get('prefix', 'ovn-scale')
        registry_node = config['registry-node']
        central_config = config['central-node']
        ovn_gw_ip = config['ovn-gw-ip']
        ext_gw_ip = config['ext-gw-ip']

        print('[kind_central]')
        internal_iface = config['internal-iface']
        central_ip = socket.gethostbyname(central_config['name'])
        generate_central(central_config, user, prefix, internal_iface, central_ip)
        print()
        print('[kind_workers]')
        generate_nodes(config['worker-nodes'], user, prefix, internal_iface)
        print()

        print('[kind_nodes:children]')
        print('kind_central')
        print('kind_workers')
        print()

        print('[kind_nodes:vars]')
        print('registry_node=' + registry_node)
        print('rundir=' + target)
        print('ovn_central_ip=' + central_ip)
        print('ovn_gw_ip=' + ovn_gw_ip)
        print('ext_gw_ip=' + ext_gw_ip)

def main():
    if len(sys.argv) != 3:
        usage(sys.argv[0])
        sys.exit(1)

    generate(sys.argv[1], sys.argv[2])

if __name__ == "__main__":
    main()
