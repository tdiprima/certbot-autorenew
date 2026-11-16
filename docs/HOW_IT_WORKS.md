# How This System Works

## 1. What It Does

This repository is a small set of shell scripts that get a web server an HTTPS certificate and keep it renewed without a human doing it by hand.

**Input → What the system does → Final output**

- **Input:** a domain name, an email address, and two credentials from the certificate provider (an EAB Key ID and an EAB HMAC key).
- **What it does:** installs Certbot, asks the certificate provider (CERTInext) for a certificate, saves it on the server, and schedules a daily renewal check that restarts Apache when a new certificate arrives.
- **Final output:** certificate files in `/etc/letsencrypt/live/<domain>/` that stay valid on their own.

A few terms used throughout:

| Term | Meaning |
|------|---------|
| **CA** (certificate authority) | The organisation that signs certificates. Browsers trust a certificate only if they trust its CA. |
| **ACME** | The protocol a server uses to request and renew certificates automatically. |
| **Certbot** | The ACME client program these scripts drive. It does the real protocol work. |
| **CERTInext** | The ACME service these scripts talk to. It sits in front of the CA. |
| **EAB** (External Account Binding) | A Key ID and secret key that prove to CERTInext which organisation is asking. |
| **ACME account** | An identity Certbot creates on the ACME server and stores on disk. Every request is made as this account. |

There is no application here, no database and no long-running service. Each script runs once, does its job and exits. The ongoing work is done by Certbot and the system scheduler.

## 2. The Whole Process in 60 Seconds

1. An admin runs the setup script on a web server and answers four prompts.
2. The script works out whether the server is Red Hat-like or Debian-like and installs Certbot the right way for it.
3. Certbot registers an ACME account with CERTInext using the EAB keys, then requests a certificate for the domain.
4. Certbot saves the certificate and remembers how it got it, including the command to restart Apache.
5. The script rehearses a renewal to prove it will work later.
6. The script makes sure something will run `certbot renew` every day: an existing systemd timer, or a new cron job.
7. From then on, the server renews its own certificate and restarts Apache each time.
8. If the CA behind CERTInext has to change, a separate switch script swaps the account and re-issues every certificate.
9. At any point, a checker script can report what Apache is actually serving and whether it is healthy.

```
  admin answers prompts
          |
          v
  +------------------+     +-------------------+     +------------------+
  | detect OS and    | --> | request the       | --> | rehearse renewal |
  | install Certbot  |     | certificate       |     | (dry run)        |
  +------------------+     +-------------------+     +------------------+
                                    |                         |
                                    v                         v
                       /etc/letsencrypt/ (certs,     +------------------+
                       account, renewal settings)    | schedule a daily |
                                    ^                | renewal check    |
                                    |                +------------------+
                                    |                         |
                                    +---- certbot renew <-----+
                                          (every day, forever)

  side tools:   switch CA (re-issue everything)   |   audit what Apache serves
```

## 3. The Major Jobs

### Job 1: Prepare the server

**What happens.** The setup script (`src/certbot/auto_cert_setup.sh`) identifies the operating system family and installs Certbot.

**Why.** The two Linux families differ in two ways that matter later: how Certbot is installed, and what the Apache service is called.

**How.** The script looks for a marker file. `/etc/redhat-release` means Red Hat, CentOS or Fedora; `/etc/debian_version` means Ubuntu or Debian. Anything else stops the script.

| Family | How Certbot is installed | Apache service name |
|--------|--------------------------|---------------------|
| Red Hat-based | `yum`, after adding the EPEL repository | `httpd` |
| Debian-based | Snap, then linked to `/usr/bin/certbot` | `apache2` |

**What comes out.** A working `certbot` command and the correct service name. The service name is carried forward and used to build the restart command in Jobs 2 and 4.

### Job 2: Get the first certificate

**What happens.** Certbot asks CERTInext for a certificate for the domain.

**Why.** This is the point of the whole system. Everything else exists to make this step succeed now and repeat later.

**What it starts with.** The four answers from the prompts: email, domain, EAB Key ID and EAB HMAC key.

**How.** The script makes one Certbot call with these choices:

- **Which server to ask.** The CERTInext directory URL is written into the script. Without it Certbot would ask Let's Encrypt.
- **Who is asking.** The EAB keys. Certbot uses them once, to register an ACME account that CERTInext ties to the organisation.
- **How to prove control of the domain.** "Standalone" mode: if the CA wants proof, Certbot briefly runs its own tiny web server to answer. The scripts do not show whether CERTInext actually demands this proof.
- **What to do afterwards.** A deploy hook, `systemctl restart <service>`, runs whenever a certificate is issued.
- **No questions.** The call is non-interactive and accepts the terms of service automatically.

**What comes out.** Three things land under `/etc/letsencrypt/`:

- the certificate and private key, in `live/<domain>/`
- the ACME account, in `accounts/`
- a renewal settings file, `renewal/<domain>.conf`, recording the server, the account, the proof method and the deploy hook

That settings file is the important part. It is what lets a later renewal run with no arguments and no human.

### Job 3: Prove renewal will work

**What happens.** The script runs `certbot renew --dry-run`.

**Why.** A renewal that fails silently weeks later means an expired certificate and a broken site. It is better to find out now, while the admin is watching.

**How.** Certbot replays the saved settings as a rehearsal and does not replace the real certificate. The script runs with "stop on any error" turned on, so a failed rehearsal aborts setup before scheduling happens.

**What comes out.** Nothing is saved. Passing is the result.

### Job 4: Schedule renewals

**What happens.** The script makes sure a renewal check runs every day.

**Why.** Certificates expire. Their lifespans keep getting shorter, so manual renewal does not scale.

**How.** One decision:

- If a systemd timer with "certbot" in its name already exists, the script leaves it alone. Certbot packages often install one.
- Otherwise it adds a line to root's crontab that runs `certbot renew` every day at 03:00 with the Apache restart hook. It first checks whether that exact line is already there, so running setup twice does not create duplicates.

**What comes out.** A daily trigger. Most days `certbot renew` looks at each certificate, sees it is not close to expiry and does nothing. When one is close, it fetches a new one using the saved settings and restarts Apache.

This is where the system stops needing people.

### Job 5: Switch to a different CA

**What happens.** The switch script (`src/certbot/switch_to_sslcom.sh`) moves every existing certificate from the emSign CA to SSL.com.

**Why.** Browsers stopped trusting an emSign root, so certificates signed by it must be replaced. The catch is that Certbot uses EAB keys only when it registers an account. Handing it new keys does nothing while the old account still exists, so renewals would keep going to the old CA.

**What it starts with.** An email address and the new SSL.com EAB keys. The HMAC key is typed without being shown on screen.

**How.** The steps run in this order, and the order matters:

1. **Find the certificates.** Search the renewal settings files for ones that point at the CERTInext server. If there are none, stop.
2. **Back up.** Copy all of `/etc/letsencrypt` to a timestamped folder next to it.
3. **Remove the old account.** Delete its folder so Certbot has no account for that server. The backup still holds a copy.
4. **Register a new account** with the new EAB keys.
5. **Repoint each certificate.** Edit its renewal settings file to name the new account, and the new server if one was given.
6. **Force a renewal** of each certificate. Because this goes through the normal renewal path, the saved proof method and Apache restart hook are reused.
7. **Check the result.** Read the issuer names out of the new certificate chain. If any still mentions emSign, or the chain cannot be read, mark that certificate as failed.

One failed certificate does not stop the others. At the end, any failure makes the script exit with an error and print the command that restores the backup.

**What comes out.** The same certificate files in the same place, now signed under a different CA. The daily schedule from Job 4 is untouched and now renews through the new account.

By default the script assumes the server URL stays the same and only the keys change. A different URL can be supplied through the `NEW_SERVER` environment variable.

### Job 6: Audit what Apache is serving

**What happens.** The checker script (`src/check_apache_certs.sh`) reports on every certificate Apache is configured to use. It changes nothing.

**Why.** Certbot can hold a perfectly good certificate while Apache points at a different, stale file. The site only works if the files Apache reads are the right ones.

**How.** It finds the Apache config folder for whichever OS family it is on, then looks at every config file that mentions a certificate. For each one it pulls out the domain, the certificate path and the key path, follows any symlinks to the real files, and reports:

- who the certificate is for, who issued it, and when it expires
- whether the private key exists and has permissions `600` (readable only by its owner)
- whether the key is RSA or elliptic-curve
- whether the key and certificate belong together

The last check is the most valuable. The script extracts the public key from the certificate and derives the public key from the private key, then compares fingerprints of the two. A mismatch means Apache will refuse to start.

**What comes out.** A report on screen for a person to read.

### The other paths

**Apache-plugin template (`src/certbot/run_after.sh`).** Despite the name, this is not a post-renewal hook. It is a fill-in-the-blanks example of a second way to do Job 2: `certbot run --apache`, where Certbot both gets the certificate and edits the Apache config to use it. It ends with a one-line `curl` command that reads a live site's expiry date from another machine. The setup script does not call it.

**Legacy acme.sh scripts (`src/acme/`).** An older version of the same idea built on a different ACME client, `acme.sh`. The setup script there differs from the Certbot one in a few ways:

- settings (domain, email, web root, web server) are edited at the top of the file instead of prompted for
- it proves domain control by writing a file into the site's web root, so the web server keeps running
- it copies the finished files to `/etc/ssl/certs/<domain>/` and prints the config lines Nginx or Apache need
- it adds a 02:00 daily cron job

It uses no EAB keys. It sets Let's Encrypt as the CA explicitly, because `acme.sh` would otherwise use its own default.

Two helpers sit beside it. One searches the usual folders for a domain's certificate files. The other diagnoses a failed request by checking DNS, whether a web server is running, port 80, web root permissions, the firewall and the recent log. Its DNS comparison is marked in the code as unreliable.

## 4. How the Pieces Work Together

The scripts never call each other. What connects them is state left on the server.

- **The OS check feeds everything after it.** It picks the install method and the service name. The service name ends up inside the deploy hook and the cron line.
- **The first request creates the state everything else depends on.** The account and the renewal settings file are written once in Job 2. The dry run, the daily renewal and the switch script all read them.
- **The renewal settings file is the handoff to the future.** Daily renewals pass no domain, server or keys. Certbot gets all of it from that file.
- **The switch script works by editing that state.** It replaces the account and rewrites the settings files, then lets the normal renewal machinery run. That is why it needs no knowledge of how each certificate was originally obtained.
- **The checker looks at the other end.** Certbot's state says what was issued. The checker reads Apache's config to see what is actually served.

```
 setup script                    switch script
      |                               |
      | creates                       | replaces account,
      v                               v edits settings
 +-----------------------------------------------+
 |  /etc/letsencrypt/                            |
 |    accounts/   renewal/*.conf   live/<domain> |
 +-----------------------------------------------+
      ^                                   |
      | reads settings,                   | files Apache
      | writes new certs                  | should point at
      |                                   v
 daily certbot renew  ---restart--->   Apache  <--- checker reads its config
```

## 5. Important External Pieces

| Piece | Role in the process |
|-------|---------------------|
| **Certbot** | Does all the real work: account registration, certificate requests, renewal decisions, storing files. The scripts only decide what to tell it. |
| **CERTInext ACME server** | The service that receives requests and returns signed certificates. Its directory URL is written into the Certbot scripts. |
| **The CA behind CERTInext** | Signs the certificates. Which CA is used depends on the EAB keys, which is why switching CA means switching accounts. |
| **systemd timers / cron** | The clock. One of them runs the daily renewal check. |
| **Apache** | The consumer of the certificate. It only picks up a new certificate when restarted, which is what the deploy hook is for. |
| **OpenSSL** | Used for inspection only: reading issuers and expiry dates, and comparing keys. |
| **yum + EPEL, or Snap** | How Certbot gets installed, depending on OS family. |
| **acme.sh** | The alternative ACME client used by the legacy scripts. |

## 6. End-to-End Example

An admin needs HTTPS on `portal.example.edu`, an Ubuntu server running Apache.

1. **Setup starts.** They run `sudo ./auto_cert_setup.sh` and enter `admin@example.edu`, `portal.example.edu`, and the two EAB keys from the CERTInext portal.
2. **Server prepared.** The script finds `/etc/debian_version`, sets the service name to `apache2`, and installs Certbot through Snap.
3. **Certificate issued.** Certbot registers an account with CERTInext and receives a certificate. It saves the files under `/etc/letsencrypt/live/portal.example.edu/`, writes `renewal/portal.example.edu.conf`, and runs `systemctl restart apache2`.
4. **Renewal rehearsed.** The dry run passes.
5. **Renewal scheduled.** A Certbot timer already exists from the Snap install, so the script adds no cron job.
6. **Life goes on.** Every day the timer runs `certbot renew`. For weeks it does nothing. When the certificate nears expiry, Certbot fetches a new one and restarts Apache.
7. **The CA changes.** Months later the organisation must move to SSL.com. The admin gets new EAB keys and runs `sudo ./switch_to_sslcom.sh`. The script lists `portal.example.edu`, backs up `/etc/letsencrypt`, replaces the account, re-issues the certificate and prints the new chain's issuers. None mention emSign, so it reports success.
8. **Confirmation.** The admin runs `sudo ./check_apache_certs.sh`. It shows Apache's config pointing at the Certbot files, the new issuer, the new expiry date, key permissions `600`, and "Key matches certificate".

## 7. The Simplest Mental Model

It takes a domain name and a pair of provider credentials, uses Certbot to trade them for a certificate, and writes down exactly how it did that. A daily timer then replays those notes forever, restarting Apache whenever a fresh certificate arrives.

When the provider changes, one script throws away the old account, makes a new one, and replays the same notes. When something looks wrong, another script reads Apache's config and tells you what is really being served.
