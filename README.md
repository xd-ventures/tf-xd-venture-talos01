# tf-xd-venture-talos01

Terraform configuration for managing OVH bare metal server for Talos OS deployment.

## Prerequisites

- Terraform >= 1.0
- OVH account with API credentials
- An existing OVH bare metal server (will be imported into Terraform state)

## OVH Authentication Setup

### 1. Create OVH API Credentials

You need to create API credentials for OVH. Follow these steps:

1. Go to the OVH API token creation page for your region:
   - EU: https://eu.api.ovh.com/createToken/
   - CA: https://ca.api.ovh.com/createToken/
   - US: https://api.us.ovhcloud.com/createToken/

2. Fill in the form:
   - **Application name**: `terraform-talos01` (or any descriptive name)
   - **Application description**: `Terraform management for Talos server`
   - **Validity**: Choose duration (or "Unlimited")
   - **Rights**: Set the following permissions:
     - `GET /dedicated/server/*`
     - `PUT /dedicated/server/*`
     - `POST /dedicated/server/*`
     - `DELETE /dedicated/server/*` (optional, for full management)

3. Click "Create keys" and save the credentials:
   - Application Key
   - Application Secret
   - Consumer Key

### 2. Configure Environment Variables

Set the following environment variables with your OVH credentials:

```bash
export OVH_ENDPOINT="ovh-eu"  # or ovh-ca, ovh-us, etc.
export OVH_APPLICATION_KEY="your_application_key"
export OVH_APPLICATION_SECRET="your_application_secret"
export OVH_CONSUMER_KEY="your_consumer_key"
```

**Tip**: Add these to your `~/.bashrc`, `~/.zshrc`, or create a `.envrc` file (if using direnv) to persist the configuration.

### 3. Alternative: Using Configuration File

Instead of environment variables, you can create an `ovh.conf` file (but this is less secure):

```ini
[default]
endpoint=ovh-eu
application_key=your_application_key
application_secret=your_application_secret
consumer_key=your_consumer_key
```

Then reference it in your Terraform provider configuration.

## Getting Started

### 1. Clone and Configure

```bash
# Copy the example tfvars file
cp terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars with your server details
# Update the service_name with your actual OVH server service name
nano terraform.tfvars
```

### 2. Find Your Server Service Name

To find your server's service name, you can:

- Check the OVH control panel: Server section will show the service name (e.g., `ns123456.ip-xx-xx-xx.eu`)
- Use the OVH API: `GET /dedicated/server`
- Use the OVH CLI if installed

### 3. Initialize Terraform

```bash
terraform init
```

### 4. Import Existing Server

Since the server is already deployed, import the management resource into Terraform state:

```bash
# Replace <service_name> with your actual OVH server service name
terraform import ovh_dedicated_server_update.talos01 <service_name>

# Example:
# terraform import ovh_dedicated_server_update.talos01 ns123456.ip-192-168-1-1.eu
```

**Note**: The data source (`data.ovh_dedicated_server.talos01`) does not need to be imported as it queries the existing infrastructure directly.

### 5. Verify Configuration

```bash
# Check what Terraform sees
terraform plan

# The plan should show no changes if the import was successful
# and your configuration matches the server state
```

### 6. Apply Changes

```bash
terraform apply
```

## Project Structure

```
.
├── versions.tf              # Terraform and provider version requirements
├── variables.tf             # Input variables
├── main.tf                  # Main infrastructure resources (OVH server)
├── outputs.tf               # Output values
├── terraform.tfvars.example # Example variable values (copy to terraform.tfvars)
└── README.md               # This file
```

## Outputs

After applying, Terraform will output:

- `server_id`: The service name/ID of the server
- `server_display_name`: The display name
- `server_state`: Current state of the server
- `server_ip`: IP address of the server

## Future Enhancements

This is a basic stub for OVH server management. Future additions may include:

- Talos OS provider integration for OS deployment and management
- Network configuration
- Backup configuration
- Monitoring setup
- Additional server management features

## Troubleshooting

### Authentication Errors

If you get authentication errors:
- Verify your environment variables are set correctly
- Check that your API credentials have the necessary permissions
- Ensure you're using the correct OVH endpoint for your region

### Import Errors

If the import fails:
- Verify the service name is correct
- Check that your API credentials have access to the server
- Ensure the server exists in your OVH account

## Security Notes

- **Never commit** `terraform.tfvars` or any file containing credentials
- Always use environment variables or secure secret management for API credentials
- The `.gitignore` file is configured to exclude sensitive files
- Regularly rotate your API keys

## Resources

- [OVH Terraform Provider Documentation](https://registry.terraform.io/providers/ovh/ovh/latest/docs)
- [OVH API Documentation](https://api.ovh.com/)
- [Terraform Documentation](https://www.terraform.io/docs)