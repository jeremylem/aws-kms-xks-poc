from diagrams import Diagram, Cluster, Edge
from diagrams.aws.storage import S3
from diagrams.aws.security import KMS
from diagrams.aws.network import ALB, Route53
from diagrams.aws.compute import EC2
from diagrams.aws.management import Cloudwatch
from diagrams.generic.compute import Rack

graph_attr = {
    "bgcolor": "white",
    "pad": "0.3",
    "splines": "spline",
    "nodesep": "0.5",
    "ranksep": "0.8",
}

with Diagram(
    "AWS KMS External Key Store (XKS)",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    outformat="png",
    filename="architecture_diagram",
):
    s3 = S3("S3\n(SSE-KMS)")

    with Cluster("AWS (eu-west-3)"):
        kms = KMS("KMS")
        logs = Cloudwatch("CloudWatch")

        with Cluster("ALB + EC2"):
            alb = ALB("ALB\n(TLS)")
            ec2 = EC2("EC2\n(xks-proxy)")

    tunnel = Rack("SSH -R\nUnix socket")

    with Cluster("Mac (local)"):
        p11kit = Rack("p11-kit\nserver")
        softhsm = Rack("SoftHSM v2\nAES-256")

    # Main flow left to right
    s3 >> Edge(label="encrypt/\ndecrypt") >> kms
    kms >> Edge(label="XKS API") >> alb >> ec2
    ec2 >> Edge(label="PKCS#11") >> tunnel
    tunnel >> Edge(label="SSH -R") >> p11kit >> softhsm

    # Side channel
    ec2 >> Edge(style="dashed", color="gray") >> logs
