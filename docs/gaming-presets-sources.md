# Gaming preset sources

Checked 2026-10-09. This is a conservative, editable starting list for store/account web services, not a complete platform protocol allowlist. No port list was used as evidence of domain purpose. All entries use exact host matching; redirects, CDNs and unrelated telemetry are not expanded into suffix wildcards.

| Platform | Exact host | Purpose | Primary source |
| --- | --- | --- | --- |
| steam | `store.steampowered.com` | store | [Source](https://store.steampowered.com/) |
| steam | `steamcommunity.com` | shared | [Source](https://steamcommunity.com/login/home/) |
| playstation | `store.playstation.com` | store | [Source](https://store.playstation.com/) |
| playstation | `id.sonyentertainmentnetwork.com` | shared | [Source](https://www.playstation.com/en-us/support/account/sign-in/) |
| xbox | `www.xbox.com` | store | [Source](https://www.xbox.com/en-US/games) |
| xbox | `account.microsoft.com` | shared | [Source](https://account.microsoft.com/account) |
| xbox | `login.live.com` | shared | [Source](https://login.live.com/) |
| epic | `store.epicgames.com` | store | [Source](https://www.epicgames.com/help/c-36624475/c-35761596/which-domains-need-to-be-whitelisted-to-reach-the-epic-servers-a15422130?lang=en-US) |
| epic | `accounts.epicgames.com` | shared | [Source](https://www.epicgames.com/help/c-36624475/c-35761596/which-domains-need-to-be-whitelisted-to-reach-the-epic-servers-a15422130?lang=en-US) |
| epic | `account-public-service-prod03.ol.epicgames.com` | shared | [Source](https://www.epicgames.com/help/c-36624475/c-35761596/which-domains-need-to-be-whitelisted-to-reach-the-epic-servers-a15422130?lang=en-US) |
| epic | `catalog-public-service-prod06.ol.epicgames.com` | shared | [Source](https://www.epicgames.com/help/c-36624475/c-35761596/which-domains-need-to-be-whitelisted-to-reach-the-epic-servers-a15422130?lang=en-US) |
| epic | `orderprocessor-public-service-ecomprod01.ol.epicgames.com` | shared | [Source](https://www.epicgames.com/help/c-36624475/c-35761596/which-domains-need-to-be-whitelisted-to-reach-the-epic-servers-a15422130?lang=en-US) |
| epic | `launcher.store.epicgames.com` | shared | [Source](https://www.epicgames.com/help/c-36624475/c-35761596/which-domains-need-to-be-whitelisted-to-reach-the-epic-servers-a15422130?lang=en-US) |

`shared` means the service can also serve account, launcher, entitlement, community or game activity. Epic documents reachability requirements; the grouping above is our conservative classification, not a vendor guarantee of game/store isolation. PlayStation account management links from the support page to the Sony account host. Microsoft account services are shared across products.

A game using the same hostname as its store follows the same proxy rule. Unlisted login/game/download endpoints follow the selected device remainder route directly. Console-native authentication endpoints are not claimed to be fully covered. Review and edit the resulting ordinary rules for a specific title; there is no automatic catalog rewrite.

Only explicitly selected current host addresses (/32 or /128) are changed. DHCP/IPv6 privacy-address changes require previewing and applying again. The wizard never adds broad UDP bypass, incoming port rules or UPnP.
