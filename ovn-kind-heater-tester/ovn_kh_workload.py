import logging
from ovn_sandbox import Sandbox

log = logging.getLogger(__name__)

class stdout_logger(object):
    def __init__(self):
        self.last_msg = None

    def write(self, message):
        self.last_msg = message.strip()
        print(self.last_msg)


class WorkerNode(Sandbox):
    def __init__(self, phys_node, container, worker_ip, worker_mac,
                 nb_remote, image_id, ovn_k8s_image_id):
        super(WorkerNode, self).__init__(phys_node, container)
        self.worker_ip = worker_ip
        self.worker_mac = worker_mac
        self.image_id = image_id
        self.ovn_k8s_image_id = ovn_k8s_image_id
        self.nb_remote = nb_remote
        self.stdout_logger = stdout_logger()

    def configure(self):
        """
        Deploys and configures a worker node.
        """
        self.phys_node.run(
            cmd=f'ovn-nbctl --db={self.nb_remote} lsp-add kind '\
                f'{self.container} ' \
                f'-- lsp-set-addresses {self.container} ' \
                f'\"{self.worker_mac} {self.worker_ip}\"',
            stdout=self.stdout_logger)

        self.phys_node.run(
            cmd=f'kind create cluster --name ovn --image {self.image_id} ' \
                f'--join --nodeip={self.worker_ip} ' \
                f'--nodemac={self.worker_mac} ' \
                f'--nodename={self.container}',
            stdout=self.stdout_logger)

        self.phys_node.run(
            cmd=f'kind load docker-image {self.ovn_k8s_image_id} --name ovn --nodes {self.container}',
            stdout=self.stdout_logger)
