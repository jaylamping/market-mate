# Zero-fee iOS sideloading chain: security and durability assessment

Research date: 2026-08-16  
Scope: a single-Principal Market Mate Approval Companion for viewing and approving or rejecting actions that can affect a real-money brokerage account. This assessment covers SideStore, StikDebug, LiveContainer, LocalDevVPN, Xcode Personal Team signing, a proposed iOS 26.2 freeze, and automatic daily refresh. It uses Apple documentation and the projects' official documentation/repositories; it does not treat community tutorials as authoritative.

## Decision

**Do not use the proposed chain for Restricted Live approvals.** It is technically possible to install and periodically refresh development-signed software with this toolchain, but it is not a safe or durable authority path for real-money trading.

The disqualifying combination is:

- free Personal Team profiles and App IDs expire after seven days, and background execution is never guaranteed;
- free provisioning does not provide Push Notifications, Associated Domains, App Attest, Personal VPN, or Network Extensions;
- StikDebug exists to debug/JIT-enable development-entitled apps and is unnecessary for a normal approval client;
- LiveContainer explicitly does not sandbox guest apps, does not apply guest entitlements, and does not support remote push notifications;
- the proposed iOS 26.2 freeze with blocked updates knowingly withholds later Apple security fixes; and
- the result depends on several separately maintained projects, device pairing, a loopback VPN, Anisette signing infrastructure, and refresh behavior outside Market Mate's control.

The **recommended zero-fee mobile path** is a responsive, authenticated Home Screen web app using Safari passkeys with Face ID, plus standards-based Web Push and Slack/SMS fallback. A direct Xcode Personal Team build is acceptable only as a Paper/read-only native user-interface prototype with no live approval authority, no broker credentials, and no production-only secrets.

When a native app is allowed to approve real-money actions, enroll in the [Apple Developer Program](https://developer.apple.com/programs/whats-included/) (currently $99 per membership year), sign and distribute the app through supported Apple channels, run a current supported iOS release, and enable the security capabilities the live design requires. Never place the live Approval Companion inside LiveContainer or attach a JIT/debugging chain to it.

## Verdict by proposal element

| Proposal element | Technically installable? | Restricted Live suitability | Decision |
|---|---:|---:|---|
| Xcode with a free Personal Team | Yes, on registered personal devices | No: seven-day profiles/App IDs, three-app device cap, and capability gaps | Paper/read-only prototype only |
| SideStore refresh | Yes, while its prerequisites continue to work | No: refresh is best-effort and expiry can make the app unavailable | Prototype convenience only |
| LocalDevVPN | Yes, using the project's App Store-signed entitlement-bearing build | No need in a normal production client; it is another availability dependency | Use only to support a Paper sideload test |
| StikDebug | Yes on supported OS/app combinations | No: debugging/JIT capability is unnecessary and expands the trusted/debug surface | Prohibited for live approval |
| LiveContainer guest app | Yes, with important limitations | No: guests are not sandboxed, entitlements are not applied, and remote push is unsupported | Prohibited for any credentialed Market Mate client |
| Daily automatic refresh | SideStore attempts it | No durability guarantee; daily scheduling, connectivity, VPN, signing, and pairing can fail | Never an availability control |
| Keep the device on iOS 26.2 and block updates | Possible as a device-administration choice | No: leaves later security fixes unapplied | Prohibited for a live approval device |

## What the chain can actually do

SideStore signs apps with a personal development certificate and attempts to refresh them before Apple's normal seven-day development period expires. Its official FAQ says a free Apple Account is limited to three active apps (including SideStore) and ten different apps/App IDs per week. Apple independently documents Personal Team limits of ten App IDs, three test devices, three apps per device, and seven-day App ID and provisioning-profile expiration. [SideStore FAQ](https://docs.sidestore.io/docs/faq), [Apple account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)

SideStore requires LocalDevVPN whenever installing, updating, or refreshing. Initial setup also requires Developer Mode, an Apple Account, trust of the developer app, and a device pairing file. SideStore says the pairing file can expire after an OS update or reset and can also expire randomly, after which a computer and iLoader are needed to replace it. [SideStore prerequisites](https://docs.sidestore.io/docs/installation/prerequisites), [SideStore installation](https://docs.sidestore.io/docs/installation/install), [SideStore pairing files](https://docs.sidestore.io/docs/advanced/pairing-file)

Signing also depends on Anisette data. SideStore's documentation says legacy shared Anisette servers could trigger Apple security and lock accounts, recommends using a separate Apple Account rather than a main account, and describes its newer v3 approach as less likely—not impossible—to encounter that problem. That is a reasonable hobbyist tradeoff, not an acceptable recovery story for a sole Principal's live approval channel. [SideStore Anisette documentation](https://docs.sidestore.io/docs/advanced/anisette)

A plausible free-account arrangement is:

1. SideStore occupies one app slot.
2. StikDebug occupies a second slot.
3. LiveContainer occupies a third slot and hosts additional guest apps to evade the installed-app slot limit.
4. LocalDevVPN supplies the loopback tunnel from an App Store-signed build because a free-signed app cannot obtain the required VPN entitlement.

That arrangement can launch software. It does **not** turn guest software into independently sandboxed, normally entitled, production-signed applications.

## Capability and control analysis

### Signing expiry, app IDs, and availability

Apple's Personal Team limits are hard lifecycle constraints: development profiles and registered identifiers expire after seven days and the app must be rebuilt or re-signed. SideStore's daily refresh attempts create time margin, but do not change the underlying expiry. [Apple account overview](https://developer.apple.com/help/account/basics/about-your-developer-account), [SideStore FAQ](https://docs.sidestore.io/docs/faq)

Apple's Background Tasks documentation states that the system—not the app—chooses when background work runs. An `earliestBeginDate` prevents a task from running earlier but does not guarantee it will run then; Apple notes that development testing can involve delays of many hours. Background pushes are also low priority, may be throttled, and are not guaranteed. Therefore, “refresh daily” is an attempt, not an uptime SLA. [Choosing background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app), [`earliestBeginDate`](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate), [Testing background tasks](https://developer.apple.com/documentation/backgroundtasks/starting_and_terminating_tasks_during_development), [Pushing background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)

Even if six refresh attempts succeed, the seventh can fail because Wi-Fi is unavailable, LocalDevVPN is disconnected, a pairing record expires, Anisette or Apple's service is unavailable, the OS changes behavior, or a project regression occurs. At profile expiry the app can become unlaunchable precisely when an urgent approval, kill, or incident response is required. Market Mate must fail closed if the approval surface is unavailable, but this chain would make avoidable fail-closed events routine.

### Entitlements cannot be manufactured by re-signing

A provisioning profile is an allowlist: each restricted entitlement claimed by an app must be authorized by its profile. Re-signing a binary or placing it in LiveContainer cannot create services absent from the profile. [Apple TN3125: provisioning profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)

Apple's current [iOS capability matrix](https://developer.apple.com/help/account/reference/supported-capabilities-ios) shows the following for a free Apple Developer/Personal Team:

| Capability | Free Personal Team | Impact on the proposed live companion |
|---|---:|---|
| Background Modes | Yes | Does not guarantee SideStore refresh or timely work |
| App Groups / Keychain Sharing | Yes | Useful primitives, but not a substitute for guest isolation or app integrity |
| Push Notifications | No | No direct APNs entitlement for the free native build |
| Associated Domains | No | No native universal links or native-app `webcredentials` association |
| App Attest | No | No Apple app-instance integrity assertion |
| Personal VPN / Network Extensions | No | The free app cannot itself receive the entitlement LocalDevVPN relies on |

The `aps-environment` value used for APNs comes from the provisioning profile. Native passkey requests require an Associated Domains entry using the `webcredentials` service, and WKWebView passkeys have the same app-domain association requirement. [APNs entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/aps-environment), [Configuring associated domains](https://developer.apple.com/documentation/xcode/configuring-an-associated-domain), [Supporting passkeys](https://developer.apple.com/documentation/authenticationservices/supporting-passkeys)

The practical result is worse than merely losing polish:

- Slack/SMS links cannot become cryptographically associated native universal links under free provisioning.
- The native client cannot implement the intended first-party passkey relationship to Market Mate.
- Native APNs cannot provide time-sensitive proposal notifications.
- The server cannot require App Attest evidence from this build.

### Face ID, Keychain, Secure Enclave, and App Attest

Apple supports nonexportable, device-bound keys protected by the Secure Enclave and can require Face ID before key use. Keychain access control can bind access to the currently enrolled biometric set. Those are valuable controls in a properly signed native app. They do not make the surrounding process trustworthy or prove the identity/integrity of the binary asking the enclave to use the key. [Protecting keys with the Secure Enclave](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave), [`SecAccessControlCreateFlags`](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags)

App Attest is the complementary server-side signal: the app creates an attested key and the server validates one-time challenges, the app identity, and assertion counters. Apple also cautions that App Attest is a risk signal, not definitive proof that an OS is uncompromised. Free Personal Team provisioning lacks App Attest altogether. [DeviceCheck and App Attest](https://developer.apple.com/documentation/devicecheck), [Validating apps that connect to your server](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server), [App Attest environment entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.devicecheck.appattest-environment)

There is also a direct design conflict: StikDebug requires the target app to carry `get-task-allow`, the development entitlement that permits debugger attachment. It is a security inference—not a claim by Apple that Secure Enclave keys become extractable—that a debugger able to control a live approval process may be able to alter what the process displays or asks a nonexportable key to sign. The correct response is to remove debugging from the authority path, not rely on key nonexportability to compensate for it.

### StikDebug and JIT are solving the wrong problem

StikDebug describes itself as an on-device debugger/JIT enabler for iOS 17.4 and later. It can inspect and terminate processes, view logs, simulate location, launch applications, and enable JIT; it requires a pairing file, a loopback VPN, and a sideloaded target carrying `get-task-allow`. Its official documentation notes additional setup after reboot and limited iOS 26 app availability. [StikDebug repository](https://github.com/StephenDev0/StikDebug), [SideStore JIT guide](https://docs.sidestore.io/docs/advanced/jit)

A Market Mate Approval Companion is a normal Swift/React Native client and has no legitimate JIT requirement. Removing StikDebug eliminates an entire debugger, pairing, VPN, and post-reboot dependency. If the app cannot operate without StikDebug, it is not a candidate for live authority.

### LiveContainer is disqualifying for a credentialed client

LiveContainer's own repository says it is a launcher rather than an emulator or hypervisor. Its documented limitations are decisive:

- guest app entitlements are not applied to the host;
- guest applications are not sandboxed and can access one another's data;
- permissions are applied globally;
- app extensions are unsupported;
- remote push notifications do not work;
- some custom URL-scheme queries do not work; and
- keychain separation is an emulation using a finite set of access groups, not normal per-app platform isolation.

The project also warns that a third-party closed-source build can access every installed guest application's data, including keychain data and login credentials. [LiveContainer repository](https://github.com/LiveContainer/LiveContainer), [LiveContainer installation](https://livecontainer.github.io/docs/installation), [LiveContainer JIT-less setup](https://livecontainer.github.io/docs/faq/jit-less-mode-setup)

Those are not acceptable limitations for software that holds a session, an approval signing key, or a proposal challenge. A trading companion must not coexist in a shared, unsandboxed guest environment with arbitrary sideloaded applications. Official builds and source review reduce—but do not remove—the architecture's lack of isolation.

### LocalDevVPN is an extra dependency, not a security boundary

LocalDevVPN creates an on-device tunnel with auto-connect for the loopback communication SideStore and StikDebug need. Its official repository says traffic stays on device and explains that its App Store-signed build supplies a VPN entitlement a free-signed user app cannot obtain. [LocalDevVPN repository](https://github.com/seomin0610/LocalDevVPN)

There is no evidence that LocalDevVPN intentionally exfiltrates traffic. The problem is architectural: the live client should not require any VPN/debug loop for signing, launch, refresh, or approval. Every extra independently updated component adds another failure and review boundary. Use LocalDevVPN only inside an isolated Paper prototype if SideStore testing genuinely requires it.

### Freezing iOS 26.2 is a security regression

Apple lets a user disable automatic iOS download or installation, but recommends current software because updates contain security fixes and bug fixes. Apple's Background Security Improvements are incremental; if unavailable or disabled, a device does not receive those protections until a later software update. [Update iPhone or iPad](https://support.apple.com/en-us/118575), [Background Security Improvements](https://support.apple.com/en-ie/102657)

Apple's published [iOS and iPadOS 26.4 security content](https://support.apple.com/en-euro/126792) includes fixes issued after 26.2 for kernel memory disclosure/write/corruption and multiple WebKit same-origin, content-security-policy, and sandbox issues. The [Apple security releases index](https://support.apple.com/en-euro/100100) is the authoritative release ledger.

Keeping a money-authority device on 26.2 to preserve a sideload/JIT workaround would therefore trade known platform security fixes for a capability the Approval Companion does not need. SideStore's own installation material covers iOS 26.x, while its JIT material describes iOS 26 compatibility limitations; that is a reason to avoid JIT, not to freeze the OS. A live approval device must stay on a current Apple-supported release, receive security updates promptly, and be recertified after significant OS updates.

## Supply-chain and support assessment

SideStore, StikDebug, LiveContainer, and LocalDevVPN are open-source projects, which permits inspection and is preferable to opaque binaries. Open source does not make a multi-project chain a supported security product. The chain spans:

- four independently released applications;
- Apple signing and Personal Team quotas;
- device pairing records;
- Anisette infrastructure and an Apple Account;
- VPN, Developer Mode, and debugger/JIT behavior;
- private or compatibility-sensitive platform techniques; and
- nightly/beta compatibility fixes when Apple changes iOS behavior.

The projects' own troubleshooting and release material records pairing replacement, refresh prerequisites, reboot setup, OS-version compatibility work, and nightly/pre-release builds. That is normal for enthusiast tooling, but it gives Market Mate no vendor SLA, coordinated incident response, security advisory contract, deterministic release cadence, or guaranteed compatibility window. [SideStore troubleshooting](https://docs.sidestore.io/docs/troubleshooting/common-issues), [SideStore error codes](https://docs.sidestore.io/docs/troubleshooting/error-codes), [LiveContainer releases](https://github.com/LiveContainer/LiveContainer/releases)

For a Paper experiment, pin exact source revisions, build official source yourself where practical, record checksums/SBOMs, isolate the Apple Account, and assume the environment can be rebuilt. Those controls still do not qualify the chain for live authority.

## Safe zero-fee path

### Preferred: authenticated Home Screen web app

A responsive Market Mate web app avoids development signing and can remain on a fully updated iPhone. Apple documents that Safari can use Face ID or Touch ID to sign in to a supporting website with a passkey. Website passkeys are bound to the relying-party domain, resist phishing, and store their private material in the user's credential system rather than the Market Mate server. [Sign in with passkeys in Safari](https://support.apple.com/guide/iphone/sign-in-with-passkeys-in-safari-iph37306ae67/ios), [Apple passkeys overview](https://developer.apple.com/passkeys/)

On iOS/iPadOS 16.4 and later, a web app added to the Home Screen can receive standards-based Web Push. WebKit explicitly says this uses APNs and does **not** require Apple Developer Program membership. iOS 26 also makes every site eligible to open as a web app when added to the Home Screen. [Web Push for iOS/iPadOS Home Screen apps](https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/), [Safari 26 web-app behavior](https://webkit.org/blog/17333/webkit-features-in-safari-26-0/)

This path should implement:

1. exact single-user server allowlisting and no public signup;
2. a passkey with user verification required for login and a fresh WebAuthn assertion for every sensitive approval;
3. a one-time, short-lived proposal challenge that binds proposal ID, instrument, legs, quantity, limit price, maximum loss, expiry, and policy version;
4. server-side authorization and risk re-evaluation immediately before action—authentication never grants blanket trade authority;
5. Slack plus SMS alerts containing no bearer credential or actionable secret, linking only to an authenticated, expiring proposal page;
6. Web Push as convenience, not the sole alert path; and
7. a fail-closed policy if fresh step-up or proposal verification cannot complete.

The Home Screen web app cannot provide native App Attest or a custom Secure Enclave proposal key, so it is a sound zero-fee initial approval surface, not the final high-assurance native design. Its security advantage over the sideload chain is that it retains browser origin isolation, phishing-resistant site-bound passkeys, current iOS security updates, and no seven-day execution cliff.

### Optional: direct Xcode Paper prototype

If native usability must be tested before enrollment, install a direct Xcode Personal Team build on the Principal's device. Do **not** use LiveContainer, StikDebug, or JIT. The build must connect only to a Paper/read-only environment, contain no broker API credentials, have no endpoint capable of creating a live approval, display a prominent `PAPER — NO LIVE AUTHORITY` banner, and tolerate reinstall every seven days. Treat all local data as disposable.

## Supported native path for Restricted Live

When native-only controls materially justify the annual fee, use a paid Apple Developer Program membership and a directly signed app. The initial beta can use TestFlight; later distribution can remain private to the Principal through an Apple-supported path selected at implementation time. The paid path should require:

- no `get-task-allow` in the distributed build and no debugger/JIT dependency;
- Associated Domains for universal links and the native passkey relationship;
- APNs for proposal notifications, with Slack/SMS redundancy;
- App Attest as one server risk signal, with replay-safe challenges and counter validation;
- a Secure Enclave-backed, nonexportable proposal key gated by current-biometric Face ID access control;
- a fresh provider/passkey step-up plus exact proposal signature for each sensitive approval;
- device and session revocation, key rotation, audit records, and a browser recovery path protected by hardware-key/passkey recovery; and
- current iOS patching, jailbreak/compromise signals, and periodic capability recertification.

The companion must never store broker credentials. It should only authenticate the Principal and approve an exact server-side proposal. Market Mate's policy/risk service remains the final authorization boundary and may still reject an authenticated approval.

## Acceptance gates

### A zero-fee Home Screen web app may enter Principal testing only if

- Face ID-backed WebAuthn registration and assertion work on the target iPhone;
- every approval requires a fresh, user-verified assertion bound to an exact one-time proposal challenge;
- copied Slack/SMS URLs are useless without authentication and expire quickly;
- replay, modified-proposal, stale-price, expired-policy, concurrent-approval, and revoked-session tests fail closed;
- Web Push, Slack, and SMS are exercised independently, with no assumption that any single channel is guaranteed; and
- loss controls and trade authorization remain server-side.

### A native app may receive Restricted Live approval authority only if

- it is built and distributed through a supported paid Apple program path;
- it runs on a current supported iOS version with security updates enabled;
- release entitlements prove `get-task-allow=false` and include the intended Associated Domains, APNs, and App Attest configuration;
- App Attest, Secure Enclave/Face ID proposal signing, universal links, passkeys, notification fallback, revocation, and recovery pass adversarial integration tests;
- no LiveContainer, StikDebug, SideStore signing, LocalDevVPN, JIT, or Anisette component is in the production dependency graph; and
- loss of the phone, biometric re-enrollment, OS update, app reinstall, membership/certificate expiry, notification outage, and auth-provider outage each have a rehearsed fail-closed response.

## Bottom line

The proposed chain answers “Can I make an unsigned native app keep launching without paying Apple?” with a qualified **yes**. It does not answer the real requirement: “Can this be the dependable, phishing-resistant, isolated, attestable approval authority for a live brokerage account?” For that requirement the answer is **no**.

Use the zero-fee Safari/Home Screen web app for the initial mobile roadmap and optionally a direct-Xcode Paper prototype for native usability research. Budget the $99/year Apple membership as a security and distribution control—not an App Store publishing expense—before enabling native Restricted Live approvals.
