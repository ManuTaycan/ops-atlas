# Troubleshoot blank Teams Speed Dial entries

Use this guide when Microsoft Teams Speed Dial shows blank entries, a previously used contact cannot be added again, or a new contact can be added while an older one cannot. It follows one historical support case. The checks below help narrow the scope; they do not identify a particular internal cause.

## What the case showed

In the original case:

- The affected user's Speed Dial problem appeared in both Teams desktop and Teams web.
- A comparison user could add the same target contact.
- The affected user could add a never-before-used contact but could not add a contact previously used in Speed Dial.
- The affected and comparison users had structurally equivalent core Teams voice-provisioning values in the properties compared. The affected user's observed `EnterpriseVoiceEnabled` value was `True`, `LineURI` was assigned, and `UserValidationErrors` was empty.
- No explicit Teams Calling Policy appeared for the affected user in the policy-assignment check. The Global policy was then inspected; the observed `AllowPrivateCalling` value was `True`.
- The same behavior was later observed for multiple users. Microsoft Support subsequently told the case owner that this case reflected a broader/global problem on Microsoft's side.

These are reported observations from that case, not a current service-health statement. The case did not establish a technical root cause or document a final Microsoft remediation.

## Diagnosis

Perform comparisons with authorized test accounts and non-sensitive test contacts. Treat outputs as private administrative data: commands can return display names, user identifiers, and phone assignments. Do not paste raw output, screenshots, or environment details into public issues or articles.

For the documented People app path, open **View more apps > People**, select a contact, and choose **Add to speed dial**. Then open **Calls** to view the updated Speed Dial. Client layouts and labels can vary.

### 1. Compare the same user's experience across clients

Reproduce the affected entry in Teams desktop and Teams web using the same account. Note whether the blank entry and inability to add the contact occur in both.

**Why this matters:** A failure isolated to one client would make a client-specific display, cache, or local-state issue more plausible and would give a reason to focus further client troubleshooting there.

**Observed in the case:** The problem appeared in both clients.

**Interpretation:** The expected comparison is that the behavior is either limited to one client or repeats across clients; neither result alone is a universal health requirement. Repetition across desktop and web makes a purely local client/cache explanation less likely. It does not prove a backend fault, identify a service component, or rule out every client-related factor.

### 2. Check whether another user can add the same target

With an authorized comparison account, try adding the same target contact to that user's Speed Dial. Do not use a real person's details in a public report.

**Why this matters:** This separates a generally unusable target from behavior that varies by user.

**Observed in the case:** The comparison user could add the same target.

**Interpretation:** The expected comparison is whether the target can be added in the working account. Success there makes a general problem with that target less likely. It does not prove that every aspect of the target is valid in the affected user's context or explain why the affected user's entry fails.

### 3. Compare a new contact with a previously used Speed Dial contact

For the affected user, compare adding a contact never previously used in Speed Dial with adding one that was previously used. Keep other conditions as similar as practical.

**Why this matters:** This tests whether the observed failure tracks with the contact's prior use for that user.

**Observed in the case:** The new contact could be added; the previously used contact could not.

**Interpretation:** The expected comparison is whether both categories behave alike. The different results strongly correlate the failure with prior contact/Speed Dial history for that user. Inconsistent or stale user-specific contact/Speed Dial state is a plausible hypothesis only. The comparison does not show that any record is stale, orphaned, tombstoned, damaged, or otherwise inconsistent, nor does it identify a storage or synchronization mechanism.

### 4. Check basic Teams voice provisioning

If the administrator has the required Teams PowerShell access, inspect the affected user's relevant properties:

```powershell
Get-CsOnlineUser -Identity '<AFFECTED_USER>' |
    Select-Object DisplayName,
                  UserPrincipalName,
                  EnterpriseVoiceEnabled,
                  LineURI,
                  UserValidationErrors
```

Use a real identity only in the private administrative session. The placeholder above is fictional; never publish a real identity or unredacted result.

**Why this matters:** These properties provide a basic check of the Teams voice configuration and reported validation state. Microsoft documents `EnterpriseVoiceEnabled` and describes `Get-CsOnlineUser` as the source for checking several prerequisites for the Teams dial pad.

**Observed in the case:** `EnterpriseVoiceEnabled` was `True`, a line URI was assigned, and `UserValidationErrors` was empty.

**Expected state:** Compare each result with the user's intended voice configuration. A `True` Enterprise Voice value, an assigned line URI where one is expected, and no reported validation errors were consistent with a working Teams Phone user in this case. These are not universal requirements for every tenant or calling setup; confirm the expected configuration for the environment.

**Interpretation:** The observed values did not point to a basic provisioning error in the properties checked. The dial-pad documentation supports interpreting these checks only. It does not say that these properties govern Speed Dial entries. Passing the checks cannot validate personal contacts or Speed Dial data, prove all calling configuration is correct, or explain the blank entries.

### 5. Check the effective Teams Calling Policy

Check the user's effective policy assignment, including direct and group assignment:

```powershell
Get-CsUserPolicyAssignment -Identity '<AFFECTED_USER>' -PolicyType TeamsCallingPolicy
```

In the case, no explicit Teams Calling Policy appeared in the result, so the Global policy was inspected:

```powershell
Get-CsTeamsCallingPolicy -Identity Global |
    Select-Object Identity,
                  AllowPrivateCalling,
                  AllowCallGroups,
                  AllowDelegation
```

**Why this matters:** Microsoft documents that `Get-CsUserPolicyAssignment` returns directly assigned and group-inherited effective assignments. If no effective policy is returned, the applicable default may be the tenant global default or the system global default. Microsoft documents that calling policies control calling features, and the dial-pad guidance uses `AllowPrivateCalling` when checking dial-pad prerequisites.

**Observed in the case:** No explicit user/group Teams Calling Policy appeared; the Global policy showed `AllowPrivateCalling = True`. The case did not report results for the other selected properties.

**Expected state:** A missing explicit assignment is not automatically an error. Determine which global default applies and inspect its current settings. For the dial-pad prerequisite specifically, Microsoft documents `AllowPrivateCalling` as needing to be enabled. Do not assume any one policy configuration is required for every organization.

**Interpretation:** The observed value was consistent with private calling being enabled under the inspected Global policy. It did not establish whether Speed Dial's contact workflow was healthy or defective. Dial-pad prerequisites are not evidence that provisioning or Calling Policy caused this Speed Dial issue.

### 6. Compare relevant provisioning values with a working user

Compare only the relevant `Get-CsOnlineUser` properties for the affected and working users. For example:

```powershell
$properties = 'EnterpriseVoiceEnabled', 'LineURI', 'UserValidationErrors'

Compare-Object `
    -ReferenceObject (Get-CsOnlineUser -Identity '<AFFECTED_USER>' | Select-Object -Property $properties) `
    -DifferenceObject (Get-CsOnlineUser -Identity '<WORKING_USER>' | Select-Object -Property $properties) `
    -Property $properties
```

Keep the comparison private and account for legitimate differences in the users' intended configuration. If `Compare-Object` returns a result, use its side indicator and selected property values to see which comparison object differs. No output means those selected values matched in this comparison, not that the accounts or all their configuration are identical.

**Why this matters:** A material difference in a relevant property can direct follow-up investigation. Equivalent values can reduce the likelihood that the properties checked explain why only one user initially failed.

**Observed in the case:** Core provisioning values were structurally equivalent. Some compared values were empty or otherwise did not distinguish the users.

**Expected state:** There is no single universal set of values for every tenant. Compare each value with the documented and intended setup, rather than treating a matching empty value as correct or incorrect by itself.

**Interpretation:** The comparison did not reveal a distinguishing core provisioning value. Equal or empty values are evidence only about the users and properties compared. They do not prove the accounts are identical, validate Speed Dial-specific state, or eliminate other causes.

### 7. Reassess scope if more users are affected

Check whether the same behavior is present for additional users, without assuming the issue is confined to one account.

**Why this matters:** A growing number of affected users changes the scope of the investigation and makes an isolated user-only explanation less sufficient.

**Observed in the case:** The behavior later appeared for multiple users. Microsoft Support then confirmed to the case owner that the problem was broader/global on Microsoft's side.

**Interpretation and limit:** This is a historical, case-specific Support outcome. It is not a current outage notice, a public Microsoft root-cause analysis, or evidence of a particular internal mechanism. No final Microsoft remediation was documented in the source case. If investigating a new occurrence, check current service health through the organization's normal channels and contact Microsoft Support with sanitized evidence when appropriate; do not infer that the historical case describes today's service state.

## Workaround: call from Outlook or a contact card

Where the user's Outlook client and account support it, open an email recipient or contact card and start a Teams call from that card. In Outlook on the web or new Outlook, Microsoft documents choosing **Call**, then **Audio call** or **Video call**. In classic Outlook, Microsoft documents selecting the contact's phone number. The available steps vary by Outlook client.

This is an alternative calling path around the affected Speed Dial workflow. It does **not** repair Speed Dial, remove blank entries, or prove that any underlying state has been fixed. The source case described this path as a workaround; it did not document a verified permanent repair through Outlook.

## Root cause, remediation, and testing status

- **Observed facts:** The cross-client reproduction, comparison-user result, new-versus-previously-used contact result, provisioning and policy observations, and later multi-user scope are the case evidence summarized above.
- **Plausible hypothesis:** Prior contact/Speed Dial history may be related to user-specific state. This was not technically proven.
- **Case-specific Support confirmation:** Microsoft Support later reported a broader/global Microsoft-side problem in that case. No public technical explanation was provided here.
- **Not established:** No tombstoned contact, orphaned identifier, damaged Speed Dial store, database record, synchronization subsystem, or other internal mechanism was confirmed as the cause.
- **Final remediation:** The source case did not document one. This guide does not claim a permanent fix.
- **Practical-test status:** The diagnostic observations above are reported from the original case; this article's authors have not rerun the commands or reproduced the issue. The Outlook path is documented by Microsoft, but its successful use in the original environment was not recorded. Deleting and recreating all personal contacts was not performed and is not presented as a test or recommendation.

## Sources and source-check date

Microsoft primary documentation checked on **2026-10-01**:

- [Manage your contacts with the People App in Teams](https://support.microsoft.com/en-us/teams/calls-devices/manage-your-contacts-with-the-people-app-in-teams) — contact types, adding contacts, and adding contacts to Speed Dial.
- [Teams dial pad access](https://learn.microsoft.com/en-us/microsoftteams/dial-pad-configuration) — used only to interpret the Enterprise Voice, validation-error, and private-calling checks; it does not establish a Speed Dial cause.
- [Get-CsUserPolicyAssignment](https://learn.microsoft.com/en-us/powershell/module/microsoftteams/get-csuserpolicyassignment?view=teams-ps) — effective direct/group assignments and global-default behavior when no effective assignment is returned.
- [Calling policies in Teams](https://learn.microsoft.com/en-us/microsoftteams/teams-calling-policy) — scope of calling-policy controls and the global policy.
- [Get-CsOnlineUser](https://learn.microsoft.com/en-us/powershell/module/skype/get-csonlineuser?view=skype-ps) — user lookup and relevant properties. Microsoft Learn currently redirects this legacy URL to its MicrosoftTeams cmdlet reference.
- [Chat or call email recipients or other contacts in Outlook](https://support.microsoft.com/en-us/outlook/mail/chat-or-call-email-recipients-or-other-contacts-in-outlook) — calling from a contact card in supported Outlook clients.
