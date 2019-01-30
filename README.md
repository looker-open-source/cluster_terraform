# Use terraform to automatically set up Looker clusters on cloud infrastructure like AWS and Azure

## Instructions
1. Download an appropriate [terraform binary](https://www.terraform.io/downloads.html) and ensure `terraform` is in your $PATH
2. **(Azure)**: Install the CLI if you are using Azure:
`curl -L https://aka.ms/InstallAzureCli | bash`, then login from the command line by typing `az login`
3. Open a shell and clone this repository into an empty directory
4. Change the directory to either `aws-cluster` or `azure-cluster` depending on your choice
5. Set values for a few variables:

    **(Azure)**: set a unique prefix in the [variables.tf](https://github.com/drewgillson/looker_cluster_terraform/blob/master/azure-cluster/variables.tf) file to prevent DNS namespace collisions.

    **(AWS)**: set your access key and secret key in the [variables.tf](https://github.com/drewgillson/looker_cluster_terraform/blob/master/aws-cluster/variables.tf) file.

6. Type `terraform init` to install dependencies
7. Type `terraform apply` and wait 10-15 minutes

8. Browse to the Looker welcome screen by visiting the _Load Balanced Primary URL_ displayed at the bottom of the output.

9. You will need to accept the unsafe self-signed certificate!