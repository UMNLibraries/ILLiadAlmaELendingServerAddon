-- ============================================================
-- ALMA LICENSE CHECK (v2.0.0)
-- Features: Multi-queue, Auto-Route Toggle, Comprehensive License Logging
-- ============================================================

luanet.load_assembly("System")
luanet.load_assembly("System.Data")
luanet.load_assembly("System.Web")
luanet.load_assembly("log4net")

local ServicePointManager = luanet.import_type("System.Net.ServicePointManager")
local SecurityProtocolType = luanet.import_type("System.Net.SecurityProtocolType")
local WebClient = luanet.import_type("System.Net.WebClient")
local HttpUtility = luanet.import_type("System.Web.HttpUtility")
local LogManager = luanet.import_type("log4net.LogManager")
local log = LogManager.GetLogger("AtlasSystems.Addons.AlmaLicenseCheck")

require "JsonParser"

local Settings = {}
local isCurrentlyProcessing = false

function Init()
    pcall(function()
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12
    end)

    Settings.BaseUrl = GetSetting("BaseUrl")
    Settings.PrimoApiKey = GetSetting("PrimoApiKey")
    Settings.AlmaApiKey = GetSetting("AlmaApiKey")
    Settings.PrimoInst = GetSetting("PrimoInst")
    Settings.PrimoVid = GetSetting("PrimoVid")
    Settings.PrimoTab = GetSetting("PrimoTab")
    Settings.PrimoScope = GetSetting("PrimoScope")
    
    Settings.ProcessQueue = GetSetting("ProcessQueue")
    Settings.AutoRoute = GetSetting("AutoRoute")
    Settings.SuccessQueue = GetSetting("SuccessQueue")
    Settings.DenyQueue = GetSetting("DenyQueue")
    Settings.NotFoundQueue = GetSetting("NotFoundQueue")

    RegisterSystemEventHandler("SystemTimerElapsed", "TimerElapsed")
    log:Debug("Alma License Check: Initialized (v2.0.0).")
end

function TimerElapsed()
    if isCurrentlyProcessing then return end
    isCurrentlyProcessing = true

    local success, err = pcall(function() ProcessTransactions() end)
    if not success then log:Error("CRITICAL ERROR: " .. tostring(err)) end

    isCurrentlyProcessing = false
end

function ProcessTransactions()
    log:Debug("Alma Check: Scanning Queues: " .. Settings.ProcessQueue)
    local connection = CreateManagedDatabaseConnection()
    
    local dbSuccess, dbErr = pcall(function()
        connection:Connect()
        
        -- Parse comma-separated queues into a SQL IN clause
        local queueList = {}
        for q in string.gmatch(Settings.ProcessQueue, '([^,]+)') do
            -- Trim whitespace and wrap in single quotes
            table.insert(queueList, "'" .. q:match("^%s*(.-)%s*$") .. "'")
        end
        local queueSql = table.concat(queueList, ", ")

        local query = [[
            SELECT TransactionNumber, ESPNumber, ISSN, LoanTitle, PhotoJournalTitle 
            FROM Transactions 
            WHERE TransactionStatus IN (]] .. queueSql .. [[)
        ]]

        -- If AutoRoute is off, prevent infinite loops by ignoring TNs that already have our note
        if not Settings.AutoRoute then
            query = query .. [[
                AND TransactionNumber NOT IN (
                    SELECT TransactionNumber FROM Notes WHERE Note LIKE 'Alma Check:%'
                )
            ]]
        end

        connection.QueryString = query
        local results = connection:Execute()
        local transactionsToProcess = {}
        
        if results and results.Rows then
            local rows = results.Rows
            for i = 0, 100 do
                local success, row = pcall(function() return rows:get_Item(i) end)
                if not success or not row then break end

                local data = {}
                data.TN = GetCol(row, "TransactionNumber")
                data.OCLC = GetCol(row, "ESPNumber")
                data.ISSN = GetCol(row, "ISSN")
                data.LoanTitle = GetCol(row, "LoanTitle")
                data.ArticleTitle = GetCol(row, "PhotoJournalTitle")

                if data.TN and data.TN ~= "" then table.insert(transactionsToProcess, data) end
            end
        end

        log:Debug("Alma Check: Found " .. #transactionsToProcess .. " transactions to process.")

        for _, txnData in ipairs(transactionsToProcess) do
            local procSuccess, procErr = pcall(function() EvaluateTransaction(txnData) end)
            if not procSuccess then
                log:Error("Error processing TN " .. tostring(txnData.TN) .. ": " .. tostring(procErr))
                ExecuteCommand("AddNote", {tonumber(txnData.TN), "Alma Addon Error: " .. tostring(procErr)})
            end
        end
    end)

    if not dbSuccess then log:Error("Database Execution Failed: " .. tostring(dbErr)) end
    connection:Dispose()
end

function GetCol(row, colName)
    local val = nil
    pcall(function() val = row:get_Item(colName) end)
    if val == nil or tostring(val) == "System.DBNull" then return "" end
    return tostring(val)
end

function EvaluateTransaction(data)
    local tn = tonumber(data.TN)
    ExecuteCommand("AddNote", {tn, "Alma Check: Starting evaluation..."})

    -- Retrieves a LIST of MMS IDs rather than stopping at the first match
    local mmsIds = GetMmsIdsSmart(tn, data.OCLC, data.ISSN, data.LoanTitle or data.ArticleTitle)

    if mmsIds and #mmsIds > 0 then
        log:Debug("TN " .. tn .. ": Electronic Match Found. Checking " .. #mmsIds .. " records.")
        
        local isAllowed = false
        local allLicenses = {}
        
        -- Check every matched record and gather valid licenses
        for _, mmsId in ipairs(mmsIds) do
            local allowed, licenses = CheckAlmaLending(tn, mmsId)
            if allowed and licenses then
                isAllowed = true
                for _, lic in ipairs(licenses) do
                    -- Prevent duplicate licenses in the note
                    local isDup = false
                    for _, existing in ipairs(allLicenses) do
                        if existing == lic then isDup = true break end
                    end
                    if not isDup then table.insert(allLicenses, lic) end
                end
            end
        end

        if isAllowed then
            local licenseStr = table.concat(allLicenses, ", ")
            ExecuteCommand("AddNote", {tn, "Alma Check: ALLOWED. Permitted Licenses found: " .. licenseStr})
            if Settings.AutoRoute then
                ExecuteCommand("Route", {tn, Settings.SuccessQueue})
            end
        else
            ExecuteCommand("AddNote", {tn, "Alma Check: DENIED. No permitted terms found on any matching records."})
            if Settings.AutoRoute then
                ExecuteCommand("Route", {tn, Settings.DenyQueue})
            end
        end
    else
        ExecuteCommand("AddNote", {tn, "Alma Check: Not Found (or no electronic portfolios)."})
        if Settings.AutoRoute then
            ExecuteCommand("Route", {tn, Settings.NotFoundQueue})
        end
    end
end

-- ==========================================
-- SMART SEARCH LOGIC (AGGREGATING ALL RESULTS)
-- ==========================================

function GetMmsIdsSmart(tn, oclc, isxn, title)
    local validMmsIds = {}
    local checkedMmsIds = {}

    local function CheckList(mmsList)
        if not mmsList then return end
        for _, mms in ipairs(mmsList) do
            if not checkedMmsIds[mms] then
                checkedMmsIds[mms] = true
                if HasPortfolios(mms) then
                    log:Debug("Valid Portfolio found on MMS: " .. mms)
                    table.insert(validMmsIds, mms)
                end
            end
        end
    end

    -- 1. OCLC Exact
    if oclc and oclc ~= "" then
        CheckList(CallPrimoApi("any,contains," .. oclc))
    end
    
    -- 2. ISxN (ISBN/ISSN)
    if isxn and isxn ~= "" then
        local clean = isxn:gsub("[- ]", "")
        local field = (string.len(clean) > 9) and "isbn" or "issn"
        CheckList(CallPrimoApi(field .. ",exact," .. clean))
    end

    -- 3. OCLC Numeric Only
    if oclc and oclc ~= "" then
        local num = oclc:gsub("%D", "")
        if num ~= "" then
            CheckList(CallPrimoApi("any,contains," .. num))
        end
    end

    -- 4. Title (Fallback only if nothing found yet, prevents API flooding)
    if #validMmsIds == 0 and title and title ~= "" then
        CheckList(CallPrimoApi("title,contains," .. title))
    end

    return validMmsIds
end

function HasPortfolios(mmsId)
    local url = string.format("%s/almaws/v1/bibs/%s/portfolios?limit=1&apikey=%s", 
        Settings.BaseUrl, mmsId, Settings.AlmaApiKey)
    
    local res = SafeDownload(url)
    if not res then return false end
    
    local json = JsonParser:ParseJSON(res)
    if json and json.total_record_count and tonumber(json.total_record_count) > 0 then
        return true
    end
    return false
end

-- ==========================================
-- API TOOLS
-- ==========================================

function SafeDownload(url)
    local client = WebClient()
    client.Headers:Add("User-Agent", "ILLiad/AlmaAddon")
    client.Headers:Add("Accept", "application/json")
    local success, res = pcall(function() return client:DownloadString(url) end)
    if not success then
        log:Error("API FAIL: " .. url .. " | Error: " .. tostring(res))
        return nil
    end
    return res
end

function CallPrimoApi(q)
    local url = string.format("%s/primo/v1/search?inst=%s&vid=%s&tab=%s&scope=%s&q=%s&apikey=%s",
        Settings.BaseUrl, Settings.PrimoInst, Settings.PrimoVid, 
        Settings.PrimoTab, Settings.PrimoScope, HttpUtility.UrlEncode(q), Settings.PrimoApiKey)
    
    local res = SafeDownload(url)
    local mmsList = {}

    if res then
        local json = JsonParser:ParseJSON(res)
        if json and json.docs then
            for _, doc in ipairs(json.docs) do
                if doc.pnx and doc.pnx.control and doc.pnx.control.sourcerecordid then
                    local ids = doc.pnx.control.sourcerecordid
                    
                    if type(ids) == "table" then
                        for _, rawId in ipairs(ids) do
                            local cleanId = rawId:gsub("alma_", "")
                            table.insert(mmsList, cleanId)
                        end
                    else
                        local cleanId = ids:gsub("alma_", "")
                        table.insert(mmsList, cleanId)
                    end
                end
            end
        end
    end
    return mmsList
end

function CheckAlmaLending(tn, mmsId)
    local url = string.format("%s/almaws/v1/bibs/%s/portfolios?apikey=%s", 
        Settings.BaseUrl, mmsId, Settings.AlmaApiKey)
    local res = SafeDownload(url)
    if not res then return false, nil end
    local json = JsonParser:ParseJSON(res)
    if not json or not json.portfolio then return false, nil end
    
    local portfolios = json.portfolio
    if portfolios.id then portfolios = { portfolios } end 

    local validLicenses = {}
    local isAllowed = false

    for _, port in ipairs(portfolios) do
        local licId = nil
        if port.license and port.license.value then
            licId = port.license.value
        elseif port.electronic_collection and port.electronic_collection.id then
            licId = GetCollectionLicense(port.electronic_collection.id.value)
        end
        if licId and CheckLicenseTerms(licId) then
            isAllowed = true
            table.insert(validLicenses, licId)
        end
    end
    return isAllowed, validLicenses
end

function GetCollectionLicense(collId)
    local url = string.format("%s/almaws/v1/electronic/e-collections/%s?apikey=%s", 
        Settings.BaseUrl, collId, Settings.AlmaApiKey)
    local res = SafeDownload(url)
    if res then
        local json = JsonParser:ParseJSON(res)
        if json.license and json.license.value then return json.license.value end
    end
    return nil
end

function CheckLicenseTerms(licId)
    local url = string.format("%s/almaws/v1/acq/licenses/%s?apikey=%s", 
        Settings.BaseUrl, licId, Settings.AlmaApiKey)
    local res = SafeDownload(url)
    if res then
        local json = JsonParser:ParseJSON(res)
        if json and json.term then
            for _, t in ipairs(json.term) do
                local c = t.code and t.code.value
                local v = t.value and t.value.value
                if v == "PERMITTED" and (c == "ILLELEC" or c == "ILLSET" or c == "ILLPRINTFAX" or c == "INTLILL") then
                    return true
                end
            end
        end
    end
    return false
end