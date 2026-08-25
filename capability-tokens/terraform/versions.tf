terraform {
  required_version = ">= 1.6"
  required_providers {
    pingoneaic = {
      source  = "registry.terraform.io/agiledigital-labs/pingone-aic"
      version = "0.1.0"
    }
  }
}

provider "pingoneaic" {
  # Everything else comes from PINGONEAIC_* in the environment: the tenant URL
  # is customer-identifying and the token is a secret, so neither belongs in a
  # committed .tf file. See README.md.
  #
  # The empty prefix is deliberate. The provider normally prepends `Terraform_`
  # so applying generated config makes copies rather than clobbering the
  # originals — but here Terraform *is* the original, and provision.sh is the
  # fallback that has to produce the identical tenant. Two spellings of every
  # name would make that comparison meaningless.
  resource_prefix = ""
}
