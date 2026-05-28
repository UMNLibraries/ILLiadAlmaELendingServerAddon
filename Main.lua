-- ============================================================
-- ALMA LICENSE CHECK (v2.0.6)
-- Description: ILLiad addon to check Alma licenses for electronic resources before routing lending requests.
-- Adds notes to transactions and routes (or doesn't) based on configurable settings.
-- Features: Search order configuration, structural syntax safety, and explicit MMS ID validation.
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

-- Explicitly separate external requirements to guarantee clean compiler parsing
require "JsonParser"

local Settings = {}
local isCurrentlyProcessing = false

-- Centralized Redaction Helper for Alma & Primo API Keys
local function Redact(value)
    if value == nil then return nil end
    local str = tostring(value)
    local keysToRedact = {}

    if Settings then
        if Settings.AlmaApiKey and Settings.AlmaApiKey ~= "" then table.insert(keysToRedact, Settings.AlmaApiKey) end
        if Settings.PrimoApiKey and Settings.PrimoApiKey ~= "" then table.insert(keysToRedact, Settings.PrimoApiKey) end
    end

    for _, key in ipairs(keysToRedact) do
        local literalPattern = key:gsub("(%W)", "%%%1")
        str = str:gsub(literalPattern, "[REDACTED]")
    end
    return str
end

-- Extracts nested error messages and HTTP response streams safely
local function GetExceptionMessage(ex)
    if ex == nil then return "" end
    local msg = tostring(ex)
    pcall(function()
        if type(ex) == "userdata" then
            if ex.Message then
                msg = ex.Message
            end
            local inner = ex.InnerException
            if inner then
                msg = msg .. "\nInner Exception: " .. tostring(inner.Message)
                if inner.Response then
                    local reader = luanet.import_type("System.IO.StreamReader")(inner.Response:GetResponseStream())
                    msg = msg .. "\nResponse Body: " .. tostring(reader:ReadToEnd())
                    reader:Close()
                end
            end
            if ex.Response then
                local reader = luanet.import_type("System.IO.StreamReader")(ex.Response:GetResponseStream())
                msg = msg .. "\nResponse Body: " .. tostring(reader:ReadToEnd())
                reader:Close()
            end
        end
    end)
    return msg
end

function Init()
    pcall(function()
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12
    end)

    -- Retrieve BaseUrl and safely sanitize trailing slashes to avoid gateway double-slash 400 errors
    local baseUrl = GetSetting("BaseUrl")
    if baseUrl then
        Settings.BaseUrl = baseUrl:gsub("/+$", "")
    else
        Settings.BaseUrl = ""
    end

    Settings.PrimoApiKey = GetSetting("PrimoApiKey")
    Settings.AlmaApiKey = GetSetting("AlmaApiKey")
    Settings.PrimoInst = GetSetting("PrimoInst")
    Settings.PrimoVid = GetSetting("PrimoVid")
    Settings.PrimoTab = GetSetting("PrimoTab")
    Settings.PrimoScope = GetSetting("PrimoScope")
    Settings.SearchOptions = GetSetting("SearchOptions")
    Settings.ProcessQueue = GetSetting("ProcessQueue")
    Settings.AutoRoute = GetSetting("AutoRoute")
    Settings.SuccessQueue = GetSetting("SuccessQueue")
    Settings.DenyQueue = GetSetting("DenyQueue")
    Settings.NotFoundQueue = GetSetting("NotFoundQueue")

    RegisterSystemEventHandler("SystemTimerElapsed", "TimerElapsed")
    log:Debug("Alma License Check: Initialized (v2.0.6).")
end

function TimerElapsed()
    if isCurrentlyProcessing then return end
    isCurrentlyProcessing = true

    local success, err = pcall(function() ProcessTransactions() end)
    if not success then log:Error("CRITICAL ERROR: " .. Redact(GetExceptionMessage(err))) end

    isCurrentlyProcessing = false
end

function ProcessTransactions()
    log:Debug("Alma Check: Scanning Queues: " .. Settings.ProcessQueue)
    local connection = CreateManagedDatabaseConnection()
    
    local dbSuccess, dbErr = pcall(function()
        connection:Connect()
        
        -- Parse comma-separated queues into a SQL IN clause and safely escape single quotes
        local queueList = {}
        for q in string.gmatch(Settings.ProcessQueue, '([^,]+)') do
            local trimmed = q:match("^%s*(.-)%s*$")
            local escaped = trimmed:gsub("'", "''")
            table.insert(queueList, "'" .. escaped .. "'")
        end
        local queueSql = table.concat(queueList, ", ")

        local query = [[
            SELECT TransactionNumber, ESPNumber, ISSN, LoanTitle, PhotoJournalTitle, PhotoArticleTitle, RequestType 
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
            -- Dynamically evaluate all rows returned from the query
            for i = 0, results.Rows.Count - 1 do
                local success, row = pcall(function() return rows:get_Item(i) end)
                if not success or not row then break end

                local data = {}
                data.TN = GetCol(row, "TransactionNumber")
                data.OCLC = GetCol(row, "ESPNumber")
                data.ISSN = GetCol(row, "ISSN")
                data.LoanTitle = GetCol(row, "LoanTitle")
                -- FIXED: Assigned journal title and article title to distinct target properties
                data.JournalTitle = GetCol(row, "PhotoJournalTitle")
                data.ArticleTitle = GetCol(row, "PhotoArticleTitle")
                data.RequestType = GetCol(row, "RequestType")

                if data.TN and data.TN ~= "" then table.insert(transactionsToProcess, data) end
            end
        end

        log:Debug("Alma Check: Found " .. #transactionsToProcess .. " transactions to process.")

        for _, txnData in ipairs(transactionsToProcess) do
            local procSuccess, procErr = pcall(function() EvaluateTransaction(txnData) end)
            if not procSuccess then
                local errMsg = GetExceptionMessage(procErr)
                log:Error("Error processing TN " .. tostring(txnData.TN) .. ": " .. Redact(errMsg))
                ExecuteCommand("AddNote", {tonumber(txnData.TN), "Alma Addon Error: " .. Redact(errMsg)})
            end
        end
    end)

    if not dbSuccess then log:Error("Database Execution Failed: " .. Redact(GetExceptionMessage(dbErr))) end
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

    local mmsIds = GetMmsIdsSmart(data)

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

function CleanTitle(title)
    if not title or title == "" then return "" end
    
    local clean = title:gsub("[^%w%s%-%']", " ")
    clean = clean:gsub("%s+", " ")
    clean = clean:match("^%s*(.-)%s*$")
    
    if string.len(clean) > 60 then
        clean = string.sub(clean, 1, 60)
        clean = clean:match("(.*)%s") or clean
    end
    
    return clean
end

-- ==========================================
-- SMART SEARCH LOGIC (AGGREGATING ALL RESULTS)
-- ==========================================

function GetMmsIdsSmart(data)
    local validMmsIds = {}
    local checkedMmsIds = {}

    local function CheckList(mmsList)
        if not mmsList then return end
        for _, mms in ipairs(mmsList) do
            if not checkedMmsIds[mms] then
                checkedMmsIds[mms] = true
                if HasPortfolios(mms) then
                    table.insert(validMmsIds, mms)
                end
            end
        end
    end

    for option in string.gmatch(Settings.SearchOptions, '([^,]+)') do
        local key = option:match("^%s*(.-)%s*$"):upper()

        if key == "OCLC" and data.OCLC ~= "" then
            CheckList(CallPrimoApi("any", "contains", data.OCLC))
        
        elseif key == "ISSN" and data.ISSN ~= "" then
            local clean = data.ISSN:gsub("[- ]", "")
            local field = (string.len(clean) > 9) and "isbn" or "issn"
            CheckList(CallPrimoApi(field, "exact", clean))

        elseif key == "TITLE" then
            -- Prefer checking the journal catalog record first; fall back to the article name if empty
            local rawTitle = ""
            if data.RequestType == "Article" then
                if data.JournalTitle and data.JournalTitle ~= "" then
                    rawTitle = data.JournalTitle
                else
                    rawTitle = data.ArticleTitle
                end
            else
                rawTitle = data.LoanTitle
            end

            local targetTitle = CleanTitle(rawTitle)
            if targetTitle and targetTitle ~= "" then
                log:Debug("Searching by Cleaned " .. data.RequestType .. " Title: " .. targetTitle)
                CheckList(CallPrimoApi("title", "contains", targetTitle))
            end
        end
        if #validMmsIds > 0 then break end
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
    client:Dispose() -- Explicitly clear connections
    
    if not success then
        local errMsg = GetExceptionMessage(res)
        log:Error("API FAIL: " .. Redact(url) .. " | Error: " .. Redact(errMsg))
        return nil
    end
    return res
end

-- Safe components composition prevents parsing comma encoding 400 issues
function CallPrimoApi(field, precision, value)
    local encodedValue = HttpUtility.UrlEncode(value)
    local qStr = string.format("%s,%s,%s", field, precision, encodedValue)

    local url = string.format("%s/primo/v1/search?inst=%s&vid=%s&tab=%s&scope=%s&q=%s&apikey=%s",
        Settings.BaseUrl, Settings.PrimoInst, Settings.PrimoVid, 
        Settings.PrimoTab, Settings.PrimoScope, qStr, Settings.PrimoApiKey)
    
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
                            -- Strict Validation: Filter non-Alma IDs to prevent Alma API 400 errors
                            if cleanId:match("^99%d+$") then
                                table.insert(mmsList, cleanId)
                            else
                                log:Debug("Ignoring non-Alma ID found in Primo results: " .. cleanId)
                            end
                        end
                    else
                        local cleanId = ids:gsub("alma_", "")
                        -- Strict Validation: Filter non-Alma IDs to prevent Alma API 400 errors
                        if cleanId:match("^99%d+$") then
                            table.insert(mmsList, cleanId)
                        else
                            log:Debug("Ignoring non-Alma ID found in Primo results: " .. cleanId)
                        end
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
        
        if licId then
            local permitted, licName = CheckLicenseTerms(licId)
            if permitted then
                isAllowed = true
                
                local displayString = licId
                if licName and licName ~= "" then
                    displayString = licName .. " (" .. licId .. ")"
                end
                
                table.insert(validLicenses, displayString)
            end
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
        if json and json.license and json.license.value then return json.license.value end
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