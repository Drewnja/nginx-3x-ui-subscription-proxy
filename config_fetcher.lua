local http = require "resty.http"
local cjson = require "cjson"

-- Check if request is from a web browser
local user_agent = ngx.var.http_user_agent or ""
local accept_header = ngx.var.http_accept or ""
local is_browser = string.match(user_agent:lower(), "mozilla") or 
                   string.match(accept_header:lower(), "text/html")

-- Получаем список серверов из переменной окружения
local servers_str = os.getenv("SERVERS")
if not servers_str then
    ngx.log(ngx.ERR, "No servers found in environment variable")
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Разделяем строку на таблицу серверов
local servers = {}
for server in string.gmatch(servers_str, "[^%s]+") do
    table.insert(servers, server)
end

-- Function to extract data from subscription template
local function extract_subscription_data(html_content)
    local data = {}
    
    -- Extract individual data attributes with more specific patterns
    local template_pattern = '<template[^>]+id="subscription%-data"[^>]*>'
    local template_start = string.find(html_content, template_pattern)
    
    if template_start then
        local template_end = string.find(html_content, '</template>', template_start)
        if template_end then
            local template_tag = string.sub(html_content, template_start, template_end)
            
            data.sid = string.match(template_tag, 'data%-sid="([^"]*)"') or ""
            data.sub_url = string.match(template_tag, 'data%-sub%-url="([^"]*)"') or ""
            data.download = string.match(template_tag, 'data%-download="([^"]*)"') or "0B"
            data.upload = string.match(template_tag, 'data%-upload="([^"]*)"') or "0B"
            data.used = string.match(template_tag, 'data%-used="([^"]*)"') or "0B"
            data.total = string.match(template_tag, 'data%-total="([^"]*)"') or "0"
            data.expire = string.match(template_tag, 'data%-expire="([^"]*)"') or "0"
            data.lastonline = string.match(template_tag, 'data%-lastonline="([^"]*)"') or "0"
            data.downloadbyte = tonumber(string.match(template_tag, 'data%-downloadbyte="([^"]*)"') or "0") or 0
            data.uploadbyte = tonumber(string.match(template_tag, 'data%-uploadbyte="([^"]*)"') or "0") or 0
            data.totalbyte = tonumber(string.match(template_tag, 'data%-totalbyte="([^"]*)"') or "0") or 0
        end
    end
    
    -- Extract links from textarea with better pattern matching
    local links_pattern = '<textarea[^>]+id="subscription%-links"[^>]*[^>]*>([^<]*)</textarea>'
    local links_match = string.match(html_content, links_pattern)
    if links_match then
        -- Decode HTML entities
        links_match = string.gsub(links_match, "&amp;", "&")
        links_match = string.gsub(links_match, "&lt;", "<")
        links_match = string.gsub(links_match, "&gt;", ">")
        data.links = links_match
    end
    
    -- Extract server name from title if available
    local title_match = string.match(html_content, '<title>([^–]+)')
    if title_match then
        data.server_name = string.gsub(title_match, "%s+$", "") -- trim whitespace
    end
    
    return data
end

-- Function to generate combined web UI (beautiful Ant Design interface)
local function generate_combined_ui(combined_data, sub_id)
    local site_host = os.getenv("SITE_HOST") or "localhost"
    local site_port = os.getenv("SITE_PORT") or "1337"
    local tls_mode = os.getenv("TLS_MODE") or "off"
    
    -- Use HTTPS if TLS is enabled, or if using a real domain (not localhost)
    local protocol = "http"
    if tls_mode == "on" or (site_host ~= "localhost" and site_host ~= "127.0.0.1") then
        protocol = "https"
    end
    
    -- Build URL with port
    local combined_url = protocol .. "://" .. site_host
    
    -- Always add port explicitly to ensure it's included
    -- Only skip port if it's the default for the protocol
    if not ((protocol == "https" and site_port == "443") or (protocol == "http" and site_port == "80")) then
        combined_url = combined_url .. ":" .. site_port
    end
    
    combined_url = combined_url .. "/sub/" .. sub_id
    
    -- Use data from first server as primary, but combine totals
    local primary_data = combined_data[1] or {}
    local total_download_bytes = 0
    local total_upload_bytes = 0
    local server_count = #combined_data
    local latest_online = 0
    local earliest_expire = math.huge
    local is_unlimited = false
    
    -- Aggregate data from all servers
    for _, data in ipairs(combined_data) do
        if data.downloadbyte then total_download_bytes = total_download_bytes + data.downloadbyte end
        if data.uploadbyte then total_upload_bytes = total_upload_bytes + data.uploadbyte end
        if data.lastonline and tonumber(data.lastonline) > latest_online then
            latest_online = tonumber(data.lastonline)
        end
        if data.expire and tonumber(data.expire) > 0 and tonumber(data.expire) < earliest_expire then
            earliest_expire = tonumber(data.expire)
        end
        if data.total == "∞" or data.totalbyte == 0 then
            is_unlimited = true
        end
    end
    
    local total_used_bytes = total_download_bytes + total_upload_bytes
    
    -- Format bytes to human readable (matching the format in screenshot)
    local function format_bytes(bytes)
        if bytes >= 1024*1024*1024 then
            return string.format("%.2fGB", bytes / (1024*1024*1024))
        elseif bytes >= 1024*1024 then
            return string.format("%.2fMB", bytes / (1024*1024))
        elseif bytes >= 1024 then
            return string.format("%.2fKB", bytes / 1024)
        else
            return string.format("%.2fKB", bytes / 1024) -- Always show as KB minimum
        end
    end
    
    -- Collect all server links and decode properly
    local server_links = {}
    for i, data in ipairs(combined_data) do
        if data.links and data.links ~= "" then
            -- Split links by newline and add each as separate server
            for link in string.gmatch(data.links, "[^\r\n]+") do
                if link and string.len(string.gsub(link, "%s", "")) > 0 then
                    -- Extract and decode server name from link
                    local server_name = string.match(link, "#([^#]+)$")
                    if server_name then
                        -- URL decode the server name
                        server_name = string.gsub(server_name, "%%(%x%x)", function(hex)
                            return string.char(tonumber(hex, 16))
                        end)
                        -- Clean up the name
                        server_name = string.gsub(server_name, "^%s*(.-)%s*$", "%1") -- trim
                    else
                        server_name = (data.server_name or "Server " .. i) .. " Config"
                    end
                    table.insert(server_links, {name = server_name, url = link})
                end
            end
        end
    end
    
    -- Format dates exactly like screenshot
    local function format_date(timestamp)
        if not timestamp or timestamp == "0" or timestamp == "" then
            return "-"
        end
        local ts = tonumber(timestamp)
        if ts and ts > 0 then
            -- Convert from milliseconds to seconds if needed
            if ts > 1000000000000 then
                ts = ts / 1000
            end
            return os.date("%Y-%m-%d %H:%M:%S", ts)
        end
        return "-"
    end
    
    local expire_date = "No expiry"
    if earliest_expire ~= math.huge then
        expire_date = format_date(earliest_expire)
    end
    
    local last_online = format_date(latest_online)
    
    -- Determine status based on screenshot
    local status_text = "Unlimited"
    local status_class = "unlimited"
    if not is_unlimited then
        status_text = "Active"  
        status_class = "active"
    end
    
    local html = [[
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Subscription - ]] .. sub_id .. [[</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      margin: 0;
      padding: 20px;
      background: #f5f5f5;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
    }
    
    .container {
      background: white;
      padding: 40px;
      border-radius: 12px;
      box-shadow: 0 4px 12px rgba(0,0,0,0.1);
      text-align: center;
      max-width: 400px;
    }
    
    
    .qr-container {
      margin: 20px 0;
      padding: 20px;
      background: #fafafa;
      border-radius: 8px;
      display: inline-block;
    }
    
    #qrcode {
      width: 200px;
      height: 200px;
      cursor: pointer;
    }
    
    .copy-button {
      background: #1890ff;
      color: white;
      border: none;
      padding: 12px 24px;
      border-radius: 6px;
      font-size: 16px;
      cursor: pointer;
      margin-top: 20px;
      transition: background 0.2s;
    }
    
    .copy-button:hover {
      background: #40a9ff;
    }
    
    .url-display {
      margin: 20px 0;
      padding: 10px;
      background: #f0f0f0;
      border-radius: 4px;
      font-family: monospace;
      font-size: 12px;
      word-break: break-all;
      color: #666;
    }
    
    .message {
      position: fixed;
      top: 20px;
      right: 20px;
      background: #52c41a;
      color: white;
      padding: 12px 20px;
      border-radius: 4px;
      display: none;
    }
  </style>
  <script src="https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js"></script>
  <script src="https://unpkg.com/qrcode@1.5.3/build/qrcode.min.js"></script>
</head>

<body>
  <div class="container">
    <div>ID: ]] .. sub_id .. [[</div>
    
    <div class="qr-container">
      <canvas id="qrcode" onclick="copyToClipboard()"></canvas>
    </div>
    
    <div class="url-display">]] .. combined_url .. [[</div>
    
    <button class="copy-button" onclick="copyToClipboard()">
      📋 Copy Subscription URL
    </button>
  </div>
  
  <div id="message" class="message">Copied to clipboard!</div>

<script>
  const subUrl = ']] .. combined_url .. [[';
  
  // Generate QR code
  function generateQR() {
    const canvas = document.getElementById('qrcode');
    const ctx = canvas.getContext('2d');
    
    // Try multiple QR code libraries
    setTimeout(() => {
      // Method 1: Try the qrcode library (most reliable)
      if (typeof QRCode !== 'undefined' && QRCode.toCanvas) {
        console.log('Using QRCode.toCanvas');
        QRCode.toCanvas(canvas, subUrl, {
          width: 200,
          height: 200,
          margin: 2,
          color: {
            dark: '#000000',
            light: '#FFFFFF'
          }
        }).then(() => {
          console.log('QR code generated successfully');
        }).catch((error) => {
          console.error('QRCode.toCanvas failed:', error);
          tryQRCodeGenerator();
        });
        return;
      }
      
      tryQRCodeGenerator();
    }, 200);
  }
  
  function tryQRCodeGenerator() {
    const canvas = document.getElementById('qrcode');
    const ctx = canvas.getContext('2d');
    
    // Method 2: Try qrcode-generator library
    if (typeof qrcode !== 'undefined') {
      console.log('Using qrcode-generator');
      try {
        const qr = qrcode(0, 'M');
        qr.addData(subUrl);
        qr.make();
        
        const size = 200;
        const cellSize = size / qr.getModuleCount();
        
        canvas.width = size;
        canvas.height = size;
        
        ctx.fillStyle = '#FFFFFF';
        ctx.fillRect(0, 0, size, size);
        ctx.fillStyle = '#000000';
        
        for (let row = 0; row < qr.getModuleCount(); row++) {
          for (let col = 0; col < qr.getModuleCount(); col++) {
            if (qr.isDark(row, col)) {
              ctx.fillRect(col * cellSize, row * cellSize, cellSize, cellSize);
            }
          }
        }
        console.log('QR code generated with qrcode-generator');
        return;
      } catch (e) {
        console.error('qrcode-generator failed:', e);
      }
    }
    
    // Method 3: Manual QR code using a simple library approach
    generateManualQR();
  }
  
  function generateManualQR() {
    console.log('Using manual QR generation as final fallback');
    const canvas = document.getElementById('qrcode');
    const ctx = canvas.getContext('2d');
    
    // Use a simple online QR API as fallback
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = function() {
      canvas.width = 200;
      canvas.height = 200;
      ctx.drawImage(img, 0, 0, 200, 200);
      console.log('QR code loaded from API');
    };
    img.onerror = function() {
      console.log('API failed, showing error message');
      canvas.width = 200;
      canvas.height = 200;
      ctx.fillStyle = '#f0f0f0';
      ctx.fillRect(0, 0, 200, 200);
      ctx.fillStyle = '#ff0000';
      ctx.font = '14px Arial';
      ctx.textAlign = 'center';
      ctx.fillText('QR Generation Failed', 100, 90);
      ctx.fillText('Click button to copy', 100, 110);
    };
    
    // Try QR API
    const encodedUrl = encodeURIComponent(subUrl);
    img.src = `https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=${encodedUrl}`;
  }
  
  function copyToClipboard() {
    if (navigator.clipboard) {
      navigator.clipboard.writeText(subUrl).then(() => {
        showMessage();
      });
    } else {
      const textArea = document.createElement('textarea');
      textArea.value = subUrl;
      document.body.appendChild(textArea);
      textArea.select();
      document.execCommand('copy');
      document.body.removeChild(textArea);
      showMessage();
    }
  }
  
  function showMessage() {
    const msg = document.getElementById('message');
    msg.style.display = 'block';
    setTimeout(() => {
      msg.style.display = 'none';
    }, 2000);
  }
  
  // Generate QR when page loads
  window.addEventListener('load', generateQR);
</script>

</body>
</html>]]
    
    return html
end

-- If it's a browser request, generate combined web UI
if is_browser then
    local httpc = http.new()
    local combined_data = {}
    
    -- Fetch web UI from each server to extract data
    for _, base_url in ipairs(servers) do
        local url = base_url .. ngx.var.sub_id
        local res, err = httpc:request_uri(url, {
            method = "GET",
            ssl_verify = false,
            headers = {
                ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
                ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
                ["Accept-Language"] = "en-US,en;q=0.5"
            }
        })
        
        if res and res.status == 200 then
            local server_data = extract_subscription_data(res.body)
            if server_data.sid then
                table.insert(combined_data, server_data)
            end
        else
            ngx.log(ngx.ERR, "Error fetching web UI from ", url, ": ", err or "HTTP " .. (res and res.status or "unknown"))
        end
    end
    
    if #combined_data > 0 then
        local combined_html = generate_combined_ui(combined_data, ngx.var.sub_id)
        ngx.header.content_type = "text/html; charset=utf-8"
        ngx.print(combined_html)
    else
        ngx.status = ngx.HTTP_BAD_GATEWAY
        ngx.header.content_type = "text/html; charset=utf-8"
        ngx.print([[
        <html><body style="font-family: sans-serif; text-align: center; margin-top: 100px;">
            <h2>❌ No subscription data available</h2>
            <p>Could not fetch data from any of the configured servers.</p>
            <p>Please check your subscription ID and try again.</p>
        </body></html>
        ]])
    end
    return
end

local httpc = http.new()
local configs = {}
local subscription_metadata = {
    upload = 0,
    download = 0,
    total = 0,
    expire = 0 -- Default to 0 like reference implementation
}

-- Запрашиваем конфигурацию с каждого сервера для VPN клиентов
for _, base_url in ipairs(servers) do
    local url = base_url .. ngx.var.sub_id
    local res, err = httpc:request_uri(url, {
        method = "GET",
        ssl_verify = false,
    })

    if res and res.status == 200 then
        -- Извлекаем метаданные из заголовков
        local userinfo = res.headers["subscription-userinfo"]
        if userinfo then
            -- Парсим subscription-userinfo: upload=123; download=456; total=789; expire=1234567890
            local upload = string.match(userinfo, "upload=(%d+)")
            local download = string.match(userinfo, "download=(%d+)")
            local total = string.match(userinfo, "total=(%d+)")
            local expire = string.match(userinfo, "expire=(%d+)")
            
            if upload then subscription_metadata.upload = subscription_metadata.upload + tonumber(upload) end
            if download then subscription_metadata.download = subscription_metadata.download + tonumber(download) end
            if total then subscription_metadata.total = subscription_metadata.total + tonumber(total) end
            if expire then 
                local exp_num = tonumber(expire)
                -- Use the earliest expiration time, but handle 0 as unlimited
                if exp_num > 0 and (subscription_metadata.expire == 0 or exp_num < subscription_metadata.expire) then
                    subscription_metadata.expire = exp_num
                elseif subscription_metadata.expire == 0 and exp_num == 0 then
                    subscription_metadata.expire = 0
                end
            end
        end
        
        -- Декодируем ответ
        local decoded_config = ngx.decode_base64(res.body)
        if decoded_config then
            table.insert(configs, decoded_config)
        else
            ngx.log(ngx.ERR, "Failed to decode base64 from ", url)
        end
    else
        ngx.log(ngx.ERR, "Error fetching from ", url, ": ", err)
    end
end

-- Возвращаем объединённые конфигурации клиенту с метаданными
if #configs > 0 then
    -- Объединяем без добавления новой строки между конфигурациями
    local combined_configs = table.concat(configs)
    local encoded_combined_configs = ngx.encode_base64(combined_configs)
    
    -- Добавляем заголовки подписки для VPN приложений
    ngx.header.content_type = "text/plain; charset=utf-8"
    ngx.header["Subscription-Userinfo"] = string.format("upload=%d; download=%d; total=%d; expire=%d", 
        subscription_metadata.upload, subscription_metadata.download, 
        subscription_metadata.total, subscription_metadata.expire)
    ngx.header["Content-Disposition"] = 'attachment; filename="' .. ngx.var.sub_id .. '.txt"'
    ngx.header["Profile-Update-Interval"] = "12"
    -- Encode subscription title as base64 like 3x-ui does
    local profile_title_prefix = os.getenv("PROFILE_TITLE_PREFIX") or "Combined Subscription"
    local profile_name = profile_title_prefix .. " - " .. ngx.var.sub_id
    ngx.header["Profile-Title"] = "base64:" .. ngx.encode_base64(profile_name)
    ngx.header["Profile-Web-Page-Url"] = "https://" .. (os.getenv("SITE_HOST") or "localhost")
    
    ngx.print(encoded_combined_configs)
else
    ngx.status = ngx.HTTP_BAD_GATEWAY
    ngx.say("No configs available")
end
