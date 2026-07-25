terraform {
  required_version = "= 1.15.8"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.20, < 6.0"
    }
  }
}

provider "azurerm" {
  features {}
}
