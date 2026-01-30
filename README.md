# ILLiadAlmaELendingServerAddon
Automates Alma license terms for ILLiad Borrowing requests.
# ILLiad Alma Unmediated E-Lending Server Addon

**Version:** 2.0.3
**Type:** Server Addon (Background Service)

## Overview
This addon automates the checking of Alma license terms for ILLiad Borrowing requests. It polls a specific queue, queries the Primo/Alma APIs to determine if the requested item is held electronically, and checks the associated license terms for Interlibrary Loan permissions.

Based on the result, the request is automatically routed to a Success, Deny, or Not Found queue.

## Features
* **Waterfall Search:** Searches Primo by OCLC, ISBN/ISSN, and Title (in that order) to find the best match.
* **License Validation:** Checks Alma license terms for specific permissions (`ILLELEC`, `ILLSET`, `ILLPRINTFAX`, `INTLILL`) set to `PERMITTED`.
* **Direct SQL:** Uses optimized SQL queries to read transaction data without loading heavy ILLiad objects.
* **TLS 1.2 Enforcement:** Hardcoded security protocol to ensure compatibility with Ex Libris APIs.

## Prerequisites
* ILLiad 9.x or higher.
* Ex Libris Alma/Primo environment.
* API Keys for:
    * **Primo Search API**
    * **Alma Bibs & Electronic API**

## Installation
1.  Ensure you have the three required files:
    * `Main.lua`
    * `Config.xml`
    * `JsonParser.lua`
2.  Compress these files into a `.zip` archive.
3.  Open the **ILLiad Customization Manager**.
4.  Navigate to **Server Addons**.
5.  Click **New**, select your `.zip` file, and upload.
6.  Enable the addon and configure the settings below.

## Configuration Settings

### API Settings
* **BaseUrl:** Your regional API URL (e.g., `https://api-na.hosted.exlibrisgroup.com`).
* **PrimoApiKey:** API key with permissions for Primo Search.
* **AlmaApiKey:** API key with permissions for Alma Bibs (Read) and Acquisitions (Read).

### Primo Context
These values control where the addon searches within your catalog.
* **PrimoInst:** Institution Code.
* **PrimoVid:** View ID.
* **PrimoTab:** Search Tab.
* **PrimoScope:** Search Scope.

### Queue Management
* **ProcessQueue:** The queue the addon monitors (e.g., `Lending Testing`).
* **SuccessQueue:** Where to route items if a license permits lending.
* **DenyQueue:** Where to route items if the license forbids lending.
* **NotFoundQueue:** Where to route items if no match is found in Primo.

## Technical Notes
* **Dependency:** Requires `JsonParser.lua` in the root directory to handle API responses.
* **Logging:** Logs are written to the ILLiad System Manager log. Look for the logger name `AtlasSystems.Addons.AlmaLicenseCheck`.
