# Use terraform to automatically set up a Looker cluster in the cloud on AWS, Azure, or GCP

## Status and Support
The purpose of this repository is to give you a starting point to  deploy a Looker cluster on a cloud environment of your choice.

These terraform scripts are NOT supported or warranteed by Looker in any way. Please do not contact Looker support for issues. These scripts are provided as examples only and must be modified by you to ensure they are appropriate for your needs.

## Instructions
1. Download an appropriate [terraform binary](https://www.terraform.io/downloads.html) and ensure `terraform` is in your $PATH
2. Install the CLI for your cloud environment

    **(MacOS / Azure)**: Install the CLI if you are using Azure:
    `curl -L https://aka.ms/InstallAzureCli | bash`, then login from the command line by typing `az login`

    **(MacOS / GCP)**: Install [gcloud](https://cloud.google.com/sdk/install) if you are using GCP, then login from the command line by typing `gcloud auth application-default login` and follow these  [instructions](https://cloud.google.com/community/tutorials/managing-gcp-projects-with-terraform) to create an admin project that can provision additional projects. You will also need to
    add two more IAM bindings:
    ```
    gcloud organizations add-iam-policy-binding ${TF_VAR_org_id} \
    --member serviceAccount:terraform@${TF_ADMIN}.iam.gserviceaccount.com \
    --role roles/compute.networkUser

    gcloud organizations add-iam-policy-binding ${TF_VAR_org_id} \
    --member user:you@your-email.com \
    --role roles/compute.instanceAdmin.v1
    ```

    **(Windows)**: Please follow Microsoft and Google documentation to install dependencies in your Windows environment.

3. Open a shell and clone this repository into an empty directory
4. Change the directory to either `aws-cluster`, `azure-cluster`, or `gcp-cluster`
5. Set values for a few configuration variables that are specific to you:

    **(Azure)**: set your Azure subscription ID in the [variables.tf](https://github.com/drewgillson/looker_cluster_terraform/blob/master/azure-cluster/variables.tf) file to prevent DNS namespace collisions

    **(AWS)**: set your access key and secret key in the [variables.tf](https://github.com/drewgillson/looker_cluster_terraform/blob/master/aws-cluster/variables.tf) file

    **(GCP)**: set your SSH username, billing account ID, and organization ID in the [variables.tf](https://github.com/drewgillson/looker_cluster_terraform/blob/master/gcp-cluster/variables.tf) file 

6. Type `terraform init` to install dependencies
7. Type `terraform apply` and wait 10-15 minutes

8. Browse to the Looker welcome screen by visiting the _Load Balanced Host_ displayed at the bottom of the output. You will need to accept the unsafe self-signed certificate to access Looker.
