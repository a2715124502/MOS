# Security

MOS is an early preview. Please use the newest preview when reporting a security problem; older versions do not have a separate maintenance branch or promised response SLA.

Report vulnerabilities privately through [GitHub Security Advisories](https://github.com/a2715124502/MOS/security/advisories/new). Include affected versions, impact, and a minimal reproduction using synthetic data. Do not put credentials, private chats, or exploit details in a public issue. If private reporting is unavailable, open an issue requesting a private contact method without disclosing the vulnerability.

Use your own authenticated gateway and prefer HTTPS. MOS is a remote client: the gateway's tools, integrations, and permissions determine what an approved task can access. Local chat cache files contain unencrypted message text; see [privacy.md](docs/privacy.md).
