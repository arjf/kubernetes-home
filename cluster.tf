terraform {
  required_providers {
    k3d = {
      source  = "sneakybugs/k3d"
      version = "1.0.1"
    }
  }
}

provider "k3d" {}

resource "k3d_cluster" "kubed" {
  name       = "kubed"
  k3d_config = file("cluster.yaml") # Reads the external file
}
