from diagrams import Diagram, Cluster, Edge
from diagrams.onprem.client import Users
from diagrams.onprem.network import Nginx
from diagrams.onprem.database import PostgreSQL
from diagrams.onprem.inmemory import Redis
from diagrams.onprem.compute import Server
from diagrams.programming.framework import Spring, React
from diagrams.azure.other import Azurite


graph_attr = {
    "nodesep": "0.8",
    "ranksep": "1.2",
    "pad": "0.6",
    "splines": "ortho",
    "compound": "true",
    "newrank": "true",
    "fontname": "Arial",
}

node_attr = {"fontname": "Arial"}
edge_attr = {"fontname": "Arial", "fontsize": "10"}


with Diagram(
    "Snippet Searcher final",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
    edge_attr=edge_attr,
):

    usuario = Users("Usuario")

    with Cluster("snippetsearcher-net"):
        ui = React("UI")
        proxy = Nginx("Reverse Proxy")
        redis = Redis("Redis\n(cola)")


        with Cluster("app_default"):
            app = Spring("App")
            app_db = PostgreSQL("app-db")
            app >> app_db


        with Cluster("accessmanager_default"):
            access_manager = Spring("Access Manager")
            access_manager_db = PostgreSQL("accessmanager-db")
            access_manager >> access_manager_db


        with Cluster("runner_default"):
            runner = Spring("Runner")
            runner_db = PostgreSQL("runner-db")
            runner >> runner_db


        with Cluster("infra_default"):
            asset_service = Server("Asset Service")
            azurite = Azurite("Azurite\n(snippets)")

            asset_service >> azurite


        usuario >> proxy
        proxy >> ui
        proxy >> Edge(xlabel="/api") >> app

        app >> access_manager
        app >> runner


        app >> Edge(
            xlabel="mensajes",
            style="dashed",
            arrowhead="none",
            constraint="false",
        ) >> redis

        runner >> Edge(
            xlabel="mensajes",
            style="dashed",
            arrowhead="none",
            constraint="false",
        ) >> redis

        runner >> asset_service