<!-- wget -O - https://get.acme.sh | sh -s email=<EMAIL_ADDRESS> -->

# acme-autopilot

Automate SSL/TLS certificate management with Certbot.

## Why Automate?

Certificate lifespans are steadily decreasing, making automation essential. Manual certificate renewal is error-prone and time-consuming.

## Primary Tool: Certbot

This repository uses **Certbot** for automated certificate acquisition and renewal. The scripts support:

- Cross-platform deployment (Red Hat, CentOS, Fedora, Ubuntu, Debian)
- InCommon/CERTInext ACME integration with EAB (External Account Binding)
- Automated web server configuration
- Scheduled renewals via systemd timers or cron

## Quick Start

### Automated Setup

The main setup script handles everything:

```sh
cd src/certbot
sudo ./auto_cert_setup.sh
```

This script will:

1. Detect your OS (Red Hat-based or Debian-based)
2. Install Certbot (via EPEL on RHEL or Snap on Ubuntu/Debian)
3. Request certificates using your configured ACME server
4. Configure automatic renewals
5. Set up post-renewal hooks

### Alternative: Apache Plugin

`run_after.sh` is a template, not a hook. It shows how to get a certificate with `certbot run --apache`, where Certbot also edits the Apache config for you. Fill in the email, EAB keys and domain before running it. It ends with a `curl` command that reads a live site's expiry date from another machine.

Web server restarts after renewal are handled by the deploy hook that `auto_cert_setup.sh` saves with the certificate.

## Switching from emSign to SSL.com

Chrome removed an emSign root on October 27, 2026, and eMudhra is leaving the TLS business. Certificates issued through CERTInext with emSign as the CA must be re-issued with SSL.com as the CA.

Certbot only uses EAB keys when it registers an ACME account, so new keys are ignored while the old account exists. The switch script handles this:

```sh
cd src/certbot
sudo ./switch_to_sslcom.sh
```

Before you run it, get the new SSL.com EAB Key ID and HMAC key from the CERTInext portal.

This script will:

1. Find every certificate issued from the CERTInext ACME server
2. Back up `/etc/letsencrypt` to `/etc/letsencrypt.bak.<timestamp>`
3. Replace the old ACME account with a new one registered with the SSL.com EAB keys
4. Re-issue each certificate, keeping its saved plugin and deploy hook
5. Print each chain's issuers and fail if any still chain to emSign

Existing renewal timers and cron jobs keep working afterwards. No change is needed there.

If CERTInext gives you a different ACME directory URL, pass it in:

```sh
sudo NEW_SERVER=https://new-server.example.com/directory ./switch_to_sslcom.sh
```

To roll back a failed switch, restore the backup and restart the web server:

```sh
sudo rm -rf /etc/letsencrypt
sudo mv /etc/letsencrypt.bak.<timestamp> /etc/letsencrypt
```

## Alternative: acme.sh

Legacy scripts using acme.sh are available in `src/acme/` but Certbot is now the recommended approach.

## License

See [LICENSE](LICENSE) for details.

<br>
