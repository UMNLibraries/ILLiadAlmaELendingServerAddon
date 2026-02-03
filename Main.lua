-- ============================================================
-- ALMA LICENSE CHECK - SMART SEARCH VERSION (v1.9.5)
-- Feature: ISSN first and trying again if not electronic
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
    -- Force TLS 1.2
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
    Settings.SuccessQueue = GetSetting("SuccessQueue")
    Settings.DenyQueue = GetSetting("DenyQueue")
    Settings.NotFoundQueue = GetSetting("NotFoundQueue")

    RegisterSystemEventHandler("SystemTimerElapsed", "TimerElapsed")
    log:Debug("Alma License Check: Initialized (Smart Search Enabled).")
end

function TimerElapsed()
    if isCurrentlyProcessing then return end
    isCurrentlyProcessing = true

    local success, err = pcall(function() ProcessTransactions() end)
    if not success then log:Error("CRITICAL ERROR: " .. tostring(err)) end

    isCurrentlyProcessing = false
end

function ProcessTransactions()
    log:Debug("Alma Check: Scanning Queue: " .. Settings.ProcessQueue)
    local connection = CreateManagedDatabaseConnection()
    
    local dbSuccess, dbErr = pcall(function()
        connection:Connect()
        local query = [[
            SELECT TransactionNumber, ESPNumber, ISSN, LoanTitle, PhotoJournalTitle 
            FROM Transactions 
            WHERE TransactionStatus = ']] .. Settings.ProcessQueue .. [['
        ]]
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

        log:Debug("Alma Check: Found " .. #transactionsToProcess .. " transactions.")

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
    ExecuteCommand("AddNote", {tn, "Alma License Check: Starting..."})

    -- SMART SEARCH: Finds the best MMS ID that actually has portfolios
    local mmsId = GetMmsIdSmart(tn, data.OCLC, data.ISSN, data.LoanTitle or data.ArticleTitle)

    if mmsId then
        log:Debug("TN " .. tn .. ": Valid Electronic Match Found. MMS ID: " .. mmsId)
        local allowed, licId = CheckAlmaLending(tn, mmsId)
        if allowed then
            ExecuteCommand("AddNote", {tn, "Alma Check: ILL ALLOWED. License: " .. licId})
            ExecuteCommand("Route", {tn, Settings.SuccessQueue})
        else
            ExecuteCommand("AddNote", {tn, "Alma Check: ILL Terms NOT Found."})
            ExecuteCommand("Route", {tn, Settings.DenyQueue})
        end
    else
        ExecuteCommand("AddNote", {tn, "Alma Check: Not Found (or no electronic portfolios)."})
        ExecuteCommand("Route", {tn, Settings.NotFoundQueue})
    end
end

-- ==========================================
-- SMART SEARCH LOGIC
-- ==========================================

function GetMmsIdSmart(tn, isxn, oclc, title)
    -- Helper to check if a search result is "useful" (has portfolios)
    local function Check(queryType, val)
        local mms = CallPrimoApi(val)
        if mms then
            if HasPortfolios(mms) then
                log:Debug(queryType .. " Match (" .. mms .. ") has portfolios. Accepting.")
                return mms
            else
                log:Debug(queryType .. " Match (" .. mms .. ") is empty (Print record?). skipping...")
            end
        end
        return nil
    end

    -- 1. ISxN (ISBN/ISSN)
    if isxn and isxn ~= "" then
        local clean = isxn:gsub("[- ]", "")
        local field = (string.len(clean) > 9) and "isbn" or "issn"
        local res = Check("ISxN", field .. ",exact," .. clean)
        if res then return res end
    end

    -- 2. OCLC Numeric Only (Backup)
    if oclc and oclc ~= "" then
        local num = oclc:gsub("%D", "")
        if num ~= "" then
            local res = Check("OCLC-Num", "any,contains," .. num)
            if res then return res end
        end
    end

    -- 3. Title (Last Resort)
    if title and title ~= "" then
        -- Title searches are fuzzy, we accept the first match we find
        local mms = CallPrimoApi("title,contains," .. title)
        if mms and HasPortfolios(mms) then return mms end
    end

    return nil
end

function HasPortfolios(mmsId)
    -- Quick check: Does this Bib have *any* portfolios?
    local url = string.format("%s/almaws/v1/bibs/%s/portfolios?limit=1&apikey=%s", 
        Settings.BaseUrl, mmsId, Settings.AlmaApiKey)
    
    local res = SafeDownload(url)
    if not res then return false end
    
    local json = JsonParser:ParseJSON(res)
    -- If 'total_record_count' > 0, we have portfolios
    if json and json.total_record_count and tonumber(json.total_record_count) > 0 then
        return true
    end
    return false
end

-- ==========================================
-- STANDARD API TOOLS
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
    if res then
        local json = JsonParser:ParseJSON(res)
        if json and json.docs and json.docs[1] then
             local raw = json.docs[1].pnx.control.sourcerecordid[1]
             if raw then return raw:gsub("alma_", "") end
        end
    end
    return nil
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

    for _, port in ipairs(portfolios) do
        local licId = nil
        if port.license and port.license.value then
            licId = port.license.value
        elseif port.electronic_collection and port.electronic_collection.id then
            licId = GetCollectionLicense(port.electronic_collection.id.value)
        end
        if licId and CheckLicenseTerms(licId) then
            return true, licId
        end
    end
    return false, nil
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
