// ==UserScript==
// @name         HidenCloud Helper
// @namespace    http://tampermonkey.net/
// @version      1.2
// @description  Integrated Scan and Renewal Tool for HidenCloud
// @author       Antigravity
// @match        https://dash.hidencloud.com/store/view/*
// @match        https://dash.hidencloud.com/service/*/manage
// @match        https://dash.hidencloud.com/service/*/invoices*
// @match        https://dash.hidencloud.com/payment/invoice/*
// @grant        GM_addStyle
// @grant        GM_openInTab
// @icon         https://www.hidencloud.com/assets/images/logo.webp
// ==/UserScript==

const UI_VERSION = '1.2'

;(function () {
  'use strict'

  // --- CSS Styles ---
  const css = `
        #hc-helper-panel {
            position: fixed;
            top: 20px;
            right: 20px;
            width: 380px;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            color: #fff;
            border: none;
            border-radius: 16px;
            z-index: 10000;
            font-family: 'Inter', system-ui, -apple-system, sans-serif;
            box-shadow: 0 20px 60px rgba(0,0,0,0.4);
            display: flex;
            flex-direction: column;
            overflow: hidden;
        }
        #hc-helper-header {
            padding: 16px 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            display: flex;
            justify-content: space-between;
            align-items: center;
            cursor: move;
        }
        #hc-helper-title {
            font-weight: 700;
            font-size: 16px;
            color: #fff;
            text-shadow: 0 2px 4px rgba(0,0,0,0.2);
        }
        #hc-helper-body {
            padding: 20px;
            flex: 1;
            display: flex;
            flex-direction: column;
            gap: 16px;
        }
        .hc-btn {
            background: linear-gradient(135deg, #00ffcc 0%, #00d4aa 100%);
            color: #000;
            border: none;
            padding: 12px 20px;
            border-radius: 12px;
            font-weight: 700;
            font-size: 14px;
            cursor: pointer;
            transition: all 0.3s ease;
            text-align: center;
            box-shadow: 0 4px 14px rgba(0,255,204,0.4);
        }
        .hc-btn:hover {
            transform: translateY(-2px);
            box-shadow: 0 6px 20px rgba(0,255,204,0.5);
        }
        .hc-btn:disabled {
            background: #2a2a3e;
            color: #666;
            cursor: not-allowed;
            box-shadow: none;
            transform: none;
        }
        #hc-log-panel {
            background: rgba(0,0,0,0.3);
            backdrop-filter: blur(10px);
            flex: 1;
            min-height: 150px;
            max-height: 500px;
            overflow-y: auto;
            border-radius: 12px;
            padding: 12px;
            font-family: 'Cascadia Code', 'Courier New', monospace;
            font-size: 11px;
            color: #aaa;
            line-height: 1.5;
            border: 1px solid rgba(255,255,255,0.1);
        }
        .log-entry {
            margin-bottom: 6px;
            word-break: break-all;
            padding: 4px 8px;
            border-radius: 4px;
            background: rgba(255,255,255,0.02);
        }
        .log-success { color: #10b981; font-weight: 600; }
        .log-error { color: #ef4444; font-weight: 600; }
        .log-warn { color: #f59e0b; font-weight: 600; }
        .log-info { color: #3b82f6; }
        #hc-order-input-container {
            display: none;
            flex-direction: column;
            gap: 10px;
            padding: 16px;
            background: rgba(255,255,255,0.05);
            border-radius: 12px;
            border: 1px solid rgba(255,255,255,0.1);
        }
        #hc-order-id-input {
            padding: 12px;
            background: rgba(0,0,0,0.3);
            border: 1px solid rgba(255,255,255,0.1);
            color: #fff;
            border-radius: 8px;
            font-size: 13px;
            transition: all 0.3s ease;
        }
        #hc-order-id-input:focus {
            outline: none;
            border-color: #00ffcc;
            box-shadow: 0 0 0 3px rgba(0,255,204,0.1);
        }
        .hc-config-section {
            display: flex;
            flex-direction: column;
            gap: 12px;
            padding: 16px;
            background: rgba(255,255,255,0.05);
            border-radius: 12px;
            border: 1px solid rgba(255,255,255,0.1);
        }
        .hc-section-title {
            font-weight: 700;
            font-size: 14px;
            color: #00ffcc;
            margin-bottom: 4px;
            display: flex;
            align-items: center;
            gap: 8px;
            position: relative;
        }
        .hc-collapse-btn {
            background: transparent;
            border: none;
            color: #00ffcc;
            cursor: pointer;
            font-size: 16px;
            padding: 4px 8px;
            margin-left: auto;
            line-height: 1;
        }
        .hc-collapse-btn:hover {
            opacity: 0.7;
        }
        .hc-config-section.collapsed #hc-location-checkboxes,
        .hc-config-section.collapsed .hc-config-actions,
        .hc-config-section.collapsed .hc-config-desc {
            display: none;
        }
        .hc-config-desc {
            font-size: 12px;
            color: #9ca3af;
            margin-top: -8px;
            margin-bottom: 4px;
        }
        .hc-selected-count {
            font-size: 11px;
            color: #00ffcc;
            background: rgba(0,255,204,0.1);
            padding: 4px 10px;
            border-radius: 12px;
            font-weight: 600;
        }
        #hc-location-checkboxes {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 8px;
        }
        .hc-location-checkbox {
            display: flex;
            align-items: center;
            justify-content: center;
            cursor: pointer;
            padding: 12px 16px;
            border-radius: 8px;
            transition: all 0.3s ease;
            background: rgba(255,255,255,0.03);
            border: 2px solid rgba(255,255,255,0.1);
            position: relative;
        }
        .hc-location-checkbox:hover {
            background: rgba(255,255,255,0.08);
            transform: translateY(-2px);
            box-shadow: 0 4px 12px rgba(0,0,0,0.2);
        }
        .hc-location-checkbox.selected {
            background: rgba(0,255,204,0.2);
            border-color: #00ffcc;
            box-shadow: 0 0 20px rgba(0,255,204,0.3);
        }
        .hc-location-checkbox.disabled {
            opacity: 0.5;
            cursor: not-allowed;
            pointer-events: none;
        }
        .hc-checkbox-label {
            font-size: 12px;
            color: #e5e7eb;
            font-weight: 500;
            user-select: none;
            text-align: center;
        }
        .hc-location-checkbox.selected .hc-checkbox-label {
            color: #fff;
            font-weight: 600;
        }
        .hc-config-actions {
            display: flex;
            gap: 8px;
            margin-top: 4px;
        }
        .hc-btn-small {
            background: rgba(255,255,255,0.1);
            color: #e5e7eb;
            border: 1px solid rgba(255,255,255,0.2);
            padding: 8px 14px;
            border-radius: 8px;
            font-size: 12px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.3s ease;
            flex: 1;
        }
        .hc-btn-small:hover:not(:disabled) {
            background: rgba(255,255,255,0.15);
            transform: translateY(-1px);
        }
        .hc-btn-small:disabled {
            opacity: 0.5;
            cursor: not-allowed;
        }
        .hc-renewal-config {
            background: rgba(255,255,255,0.05);
            border-radius: 12px;
            padding: 16px;
            margin-bottom: 16px;
        }
        .hc-renewal-options {
            display: flex;
            gap: 12px;
            margin-bottom: 12px;
        }
        .hc-renewal-option-btn {
            flex: 1;
            padding: 10px 16px;
            background: rgba(255,255,255,0.1);
            border: 2px solid rgba(255,255,255,0.2);
            color: #e5e7eb;
            border-radius: 8px;
            cursor: pointer;
            font-size: 14px;
            font-weight: 600;
            transition: all 0.3s ease;
        }
        .hc-renewal-option-btn:hover {
            background: rgba(255,255,255,0.15);
            transform: translateY(-2px);
        }
        .hc-renewal-option-btn.selected {
            background: rgba(0,255,204,0.2);
            border-color: #00ffcc;
            color: #fff;
            box-shadow: 0 0 20px rgba(0,255,204,0.3);
        }
        .hc-renewal-option-btn:disabled {
            opacity: 0.5;
            cursor: not-allowed;
            pointer-events: none;
        }
        .hc-renewal-info {
            font-size: 12px;
            color: #9ca3af;
            text-align: center;
        }
    `
  GM_addStyle(css)

  // --- UI Structure ---
  const panel = document.createElement('div')
  panel.id = 'hc-helper-panel'
  panel.innerHTML = `
        <div id="hc-helper-header">
            <span id="hc-helper-title">🚀 HidenCloud Helper</span>
            <span style="font-size:11px; color:rgba(255,255,255,0.7); font-weight:500;">v${UI_VERSION}</span>
        </div>
        <div id="hc-helper-body">
            <div class="hc-config-section" id="hc-config-section">
                <div class="hc-section-title">
                    🌍 备选地区
                    <span class="hc-selected-count" id="hc-selected-count">已选 0</span>
                    <button class="hc-collapse-btn" id="hc-collapse-btn" title="收缩/展开">▲</button>
                </div>
                <div class="hc-config-desc">至少选择 1 个地区才能开始扫货</div>
                <div id="hc-location-checkboxes"></div>
                <div class="hc-config-actions">
                    <button id="hc-select-all-btn" class="hc-btn-small">✓ 全选</button>
                    <button id="hc-deselect-all-btn" class="hc-btn-small">✗ 清空</button>
                </div>
            </div>

            <div class="hc-renewal-config" id="hc-renewal-config">
                <div class="hc-section-title">⚙️ 续费配置</div>
                <div class="hc-renewal-options">
                    <button class="hc-renewal-option-btn selected" data-years="1">1年</button>
                    <button class="hc-renewal-option-btn" data-years="2">2年</button>
                </div>
                <div class="hc-renewal-info" id="hc-renewal-info">
                    需要续费: 5 次 (84天/次)
                </div>
            </div>
            <div id="hc-main-action-container">
                <button id="hc-start-btn" class="hc-btn" disabled>开始执行</button>
            </div>
            <div id="hc-log-panel"></div>
        </div>
    `
  document.body.appendChild(panel)

  const logPanel = document.getElementById('hc-log-panel')
  const startBtn = document.getElementById('hc-start-btn')
  const selectAllBtn = document.getElementById('hc-select-all-btn')
  const deselectAllBtn = document.getElementById('hc-deselect-all-btn')
  const selectedCountEl = document.getElementById('hc-selected-count')
  const collapseBtn = document.getElementById('hc-collapse-btn')
  const configSection = document.getElementById('hc-config-section')
  const renewalConfig = document.getElementById('hc-renewal-config')
  const renewalInfo = document.getElementById('hc-renewal-info')
  const renewalOptionBtns = document.querySelectorAll('.hc-renewal-option-btn')

  function log(msg, type = 'info') {
    const div = document.createElement('div')
    div.className = `log-entry log-${type}`
    div.textContent = `[${new Date().toLocaleTimeString()}] ${msg}`

    // 检查用户是否在底部 (允许10px的误差)
    const isAtBottom = logPanel.scrollHeight - logPanel.scrollTop <= logPanel.clientHeight + 10

    logPanel.appendChild(div)

    // 只有在底部时才自动滚动
    if (isAtBottom) {
      logPanel.scrollTop = logPanel.scrollHeight
    }
  }

  // --- Location Options ---
  const LOCATION_OPTIONS = [
    { id: 16, name: '🇺🇸 Virginia, US' },
    { id: 17, name: '🇫🇷 Paris, FR' },
    { id: 18, name: '🇸🇬 Singapore, SG' },
    { id: 19, name: '🇲🇽 Queretaro, MX' },
    { id: 21, name: '🇮🇳 Pune, IN' },
    { id: 22, name: '🇦🇺 Sydney, AU' },
    { id: 23, name: '🇦🇪 Dubai, AE' }
  ]

  // --- State & Config ---
  const isScanPage = window.location.href.includes('/store/view/')
  const isRenewPage = window.location.href.includes('/manage')
  const isInvoicesListPage = window.location.href.includes('/service/') && window.location.href.includes('/invoices')
  const isInvoiceDetailPage = window.location.href.includes('/payment/invoice/')

  // 根据页面类型显示/隐藏配置区域
  if (isRenewPage) {
    configSection.style.display = 'none'
    renewalConfig.style.display = 'block'
  } else {
    renewalConfig.style.display = 'none'
  }

  if (isScanPage) {
    log('检测到扫货页面')
  } else if (isRenewPage) {
    log('检测到续费管理页面')
  } else if (isInvoicesListPage) {
    log('检测到发票列表页面')
    configSection.style.display = 'none'
    renewalConfig.style.display = 'none'
    startBtn.style.display = 'none'
  } else if (isInvoiceDetailPage) {
    log('检测到发票详情页面')
    configSection.style.display = 'none'
    renewalConfig.style.display = 'none'
    startBtn.style.display = 'none'
  } else {
    log('未匹配到目标页面，面板仅供参考')
    startBtn.disabled = true
  }

  // --- Shared Utils ---
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

  // --- Collapse State Management ---
  function loadCollapseState() {
    const collapsed = localStorage.getItem('hc_config_collapsed')
    if (collapsed === 'true') {
      configSection.classList.add('collapsed')
      collapseBtn.textContent = '▼'
    }
  }

  function saveCollapseState(isCollapsed) {
    localStorage.setItem('hc_config_collapsed', isCollapsed)
  }

  function toggleCollapse() {
    const isCollapsed = configSection.classList.toggle('collapsed')
    collapseBtn.textContent = isCollapsed ? '▼' : '▲'
    saveCollapseState(isCollapsed)
  }

  // --- Config Management ---
  function loadFallbackLocations() {
    const saved = localStorage.getItem('hc_fallback_locations')
    if (saved) {
      try {
        const parsed = JSON.parse(saved)
        if (Array.isArray(parsed) && parsed.length > 0) {
          return parsed
        }
      } catch (e) {
        log('配置加载失败，使用默认配置', 'warn')
      }
    }
    return [16, 17, 18, 19, 21, 22, 23]
  }

  function autoSaveLocations() {
    const selectedBoxes = document.querySelectorAll('.hc-location-checkbox.selected')
    const selectedLocations = Array.from(selectedBoxes).map(box =>
      parseInt(box.getAttribute('data-location-id'))
    )
    localStorage.setItem('hc_fallback_locations', JSON.stringify(selectedLocations))
    updateStartButtonState()
  }

  function updateStartButtonState() {
    const selectedBoxes = document.querySelectorAll('.hc-location-checkbox.selected')
    const count = selectedBoxes.length

    selectedCountEl.textContent = `已选 ${count}`

    if (count === 0) {
      startBtn.disabled = true
    } else {
      startBtn.disabled = false
    }
  }

  function renderLocationCheckboxes() {
    const container = document.getElementById('hc-location-checkboxes')
    const currentConfig = loadFallbackLocations()

    container.innerHTML = LOCATION_OPTIONS.map(
      loc => `
      <div class="hc-location-checkbox ${
        currentConfig.includes(loc.id) ? 'selected' : ''
      }" data-location-id="${loc.id}">
        <span class="hc-checkbox-label">${loc.name}</span>
      </div>
    `
    ).join('')

    // 为每个复选框添加click事件
    const checkboxes = container.querySelectorAll('.hc-location-checkbox')
    checkboxes.forEach(cb => {
      cb.addEventListener('click', function () {
        this.classList.toggle('selected')
        autoSaveLocations()
      })
    })

    updateStartButtonState()
  }

  // --- Scan Logic (Integrated from scan.js) ---
  let isScanning = false

  function lockLocationSelection() {
    const checkboxes = document.querySelectorAll('.hc-location-checkbox')
    checkboxes.forEach(cb => cb.classList.add('disabled'))
    selectAllBtn.disabled = true
    deselectAllBtn.disabled = true
  }

  function unlockLocationSelection() {
    const checkboxes = document.querySelectorAll('.hc-location-checkbox')
    checkboxes.forEach(cb => cb.classList.remove('disabled'))
    selectAllBtn.disabled = false
    deselectAllBtn.disabled = false
  }

  async function runScan() {
    log('扫货脚本启动...', 'info')
    isScanning = true
    startBtn.textContent = '停止执行'
    startBtn.disabled = false
    lockLocationSelection()

    const config = {
      fallbackLocations: loadFallbackLocations(),
      minDelayMs: 3000,
      maxDelayMs: 8000,
      postUrl: window.location.href.replace('/store/view/', '/payment/package/'),
      priceId: document.querySelector('input[name="price_id"]')?.value || '59926',
      errorTag: '<span class="font-medium">Error!</span>'
    }

    while (isScanning) {
      const token = document.querySelector('input[name="_token"]')?.value
      if (!token) {
        log('未能从页面找到 _token，请刷新重试', 'error')
        break
      }

      if (!isScanning) {
        log('扫货已停止', 'warn')
        break
      }

      const availableOptions = Array.from(document.querySelectorAll('#location option')).filter(
        opt => opt.value && !opt.disabled
      )

      const selected = config.fallbackLocations.map(x => parseInt(x, 10)).filter(Number.isFinite)

      let locationId
      if (availableOptions.length > 0) {
        // 把现货 option 解析成数字 id
        const available = availableOptions
          .map(opt => ({
            id: parseInt(opt.value, 10),
            name: opt.innerText.trim()
          }))
          .filter(x => Number.isFinite(x.id))

        const allLocations = available.map(x => `${x.id}:${x.name}`).join(', ')
        log(`发现现货 (${available.length}个): ${allLocations}`, 'success')

        // 只在 “现货 ∩ 已选地区” 里选择
        const preferred = available.filter(x => selected.includes(x.id))

        if (preferred.length > 0) {
          const pick = preferred[Math.floor(Math.random() * preferred.length)]
          locationId = pick.id
          log(`✅ 按已选地区下单: ${pick.id} (${pick.name})`, 'success')
        } else {
          // 你没选中任何现货地区：退回现货列表（或你也可以选择“跳过等待”）
            log('⚠️ 已选地区均无现货，跳过本轮等待下一次探测', 'warn')
            const delay =
            Math.floor(Math.random() * (config.maxDelayMs - config.minDelayMs + 1)) + config.minDelayMs
            log(`等待 ${delay / 1000}s...`)
            await sleep(delay)
            continue

        }
      } else {
        // 没现货：继续用你选的地区随机探测
        locationId = selected[Math.floor(Math.random() * selected.length)]
        log(`无现货，探测已选地区: ${locationId}`, 'info')
      }





      const postBody = `_token=${token}&price_id=${config.priceId}&custom_option%5Bcpu_limit%5D=200&custom_option%5Bmemory_limit%5D=3072&custom_option%5Bdisk_limit%5D=15360&custom_option%5Bbackup_limit%5D=10240&custom_option%5Ballocation_limit%5D=2&custom_option%5Bdatabase_limit%5D=2&location=${locationId}&gateway=11&notes=`

      try {
        const response = await fetch(config.postUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: postBody,
          redirect: 'follow'
        })

        const htmlText = await response.text()
        const finalUrl = response.url

        if (htmlText.includes(config.errorTag)) {
          const match = htmlText.match(/<span class="font-medium">Error!<\/span>([\s\S]*?)<\/div>/i)
          const errorMsg = match ? match[1].replace(/<[^>]+>/g, '').trim() : '未知错误'
          log(`请求失败: ${errorMsg}`, 'warn')
        } else if (finalUrl.includes('/store/view/') || finalUrl === config.postUrl) {
          log('请求被重定向回购买页，可能库存已空', 'warn')
        } else {
          isScanning = false
          log('🚀 扫货成功！已离开购买页', 'success')
          log('💡 请前往个人中心查看并管理您的服务器', 'info')
          log(`🔗 个人中心: ${finalUrl}`, 'info')
          break
        }
      } catch (err) {
        log(`网络异常: ${err.message}`, 'error')
      }

      const delay =
        Math.floor(Math.random() * (config.maxDelayMs - config.minDelayMs + 1)) + config.minDelayMs
      log(`等待 ${delay / 1000}s...`)
      await sleep(delay)
    }

    // 扫货结束，恢复按钮状态
    startBtn.textContent = '开始执行'
    unlockLocationSelection()
    updateStartButtonState()
  }

  function stopScan() {
    isScanning = false
    log('正在停止扫货...', 'warn')
    startBtn.textContent = '开始执行'
    unlockLocationSelection()
    updateStartButtonState()
  }

  // --- Renewal Logic (Integrated from renewal.js) ---
  function updateRenewalInfo() {
    const selectedBtn = document.querySelector('.hc-renewal-option-btn.selected')
    const years = parseInt(selectedBtn?.dataset.years || '1')
    const targetDays = years * 365
    const maxDaysPerRenewal = 84
    const renewalCount = Math.ceil(targetDays / maxDaysPerRenewal)
    renewalInfo.textContent = `需要续费: ${renewalCount} 次 (84天/次)`
  }

  function selectRenewalOption(years) {
    renewalOptionBtns.forEach(btn => {
      if (btn.dataset.years === years.toString()) {
        btn.classList.add('selected')
      } else {
        btn.classList.remove('selected')
      }
    })
    updateRenewalInfo()
  }

  function disableRenewalOptions() {
    renewalOptionBtns.forEach(btn => {
      btn.disabled = true
    })
    startBtn.disabled = true
  }

  function enableRenewalOptions() {
    renewalOptionBtns.forEach(btn => {
      btn.disabled = false
    })
    startBtn.disabled = false
  }

  function getSelectedYears() {
    const selectedBtn = document.querySelector('.hc-renewal-option-btn.selected')
    return parseInt(selectedBtn?.dataset.years || '1')
  }

  async function renewOnce() {
    const form = document.querySelector('form[action*="/renew"]')
    const token = document.querySelector('input[name="_token"]')?.value

    if (!form || !token) {
      log('未找到续费表单，请确保已打开续费弹窗', 'error')
      throw new Error('未找到续费表单')
    }

    const days = 84
    log(`准备执行续费请求，天数: ${days}`, 'info')

    try {
      const response = await fetch(form.action, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'X-Requested-With': 'XMLHttpRequest'
        },
        body: new URLSearchParams({ _token: token, days: days })
      })

      if (response.ok) {
        log('✅ 续费请求成功！', 'success')
        const data = await response.json().catch(() => ({}))
        if (data.message) log(`服务器消息: ${data.message}`, 'success')
        
        // 从当前URL提取service_id
        const serviceIdMatch = window.location.href.match(/\/service\/(\d+)/)
        const serviceId = serviceIdMatch ? serviceIdMatch[1] : null
        
        return { serviceId }
      } else {
        const errorText = await response.text()
        log(`❌ 续费失败 (${response.status}): ${errorText.substring(0, 100)}`, 'error')
        throw new Error(`续费失败: ${response.status}`)
      }
    } catch (err) {
      log(`网络异常: ${err.message}`, 'error')
      throw err
    }
  }

  async function startRenewal() {
    const years = getSelectedYears()
    const targetDays = years * 365
    const renewalCount = Math.ceil(targetDays / 84)

    log(`开始续费流程: ${years}年 (${targetDays}天)`, 'info')
    log(`需要执行 ${renewalCount} 次续费`, 'info')

    // 禁用续费配置按钮
    disableRenewalOptions()

    // 保存续费进度到 sessionStorage
    sessionStorage.setItem(
      'hc_renewal_progress',
      JSON.stringify({
        total: renewalCount,
        current: 0,
        targetDays: targetDays
      })
    )

    // 执行第一次续费
    try {
      const result = await renewOnce()

      // 更新进度
      const progress = JSON.parse(sessionStorage.getItem('hc_renewal_progress'))
      progress.current = 1
      sessionStorage.setItem('hc_renewal_progress', JSON.stringify(progress))

      log(`已完成 1/${renewalCount} 次续费`, 'success')
      
      if (result && result.serviceId) {
        log('正在跳转到发票页面...', 'info')
        await sleep(1500)
        // 导航到该服务的未支付发票页面
        window.location.href = `https://dash.hidencloud.com/service/${result.serviceId}/invoices?where=unpaid`
      } else {
        log('无法获取服务ID，刷新页面...', 'warn')
        await sleep(1000)
        window.location.reload()
      }
    } catch (err) {
      log('续费失败，流程中断', 'error')
      sessionStorage.removeItem('hc_renewal_progress')
      enableRenewalOptions()
    }
  }

  async function continueRenewal() {
    const progressData = sessionStorage.getItem('hc_renewal_progress')
    if (!progressData) return

    const progress = JSON.parse(progressData)
    if (progress.current >= progress.total) {
      log('🎉 全部续费完成！', 'success')
      sessionStorage.removeItem('hc_renewal_progress')
      enableRenewalOptions()
      return
    }

    log(`继续续费流程: 第 ${progress.current + 1}/${progress.total} 次`, 'info')

    // 禁用续费配置按钮
    disableRenewalOptions()

    try {
      const result = await renewOnce()

      // 更新进度
      progress.current++
      sessionStorage.setItem('hc_renewal_progress', JSON.stringify(progress))

      if (progress.current >= progress.total) {
        log('🎉 全部续费完成！', 'success')
        sessionStorage.removeItem('hc_renewal_progress')
      }
      
      // 无论是否完成，都跳转到发票页面支付
      if (result && result.serviceId) {
        log('正在跳转到发票页面...', 'info')
        await sleep(1500)
        window.location.href = `https://dash.hidencloud.com/service/${result.serviceId}/invoices?where=unpaid`
      } else {
        log('无法获取服务ID，刷新页面...', 'warn')
        await sleep(1000)
        window.location.reload()
      }
    } catch (err) {
      log('续费失败，流程中断', 'error')
      sessionStorage.removeItem('hc_renewal_progress')
      enableRenewalOptions()
    }
  }

  async function runRenewal() {
    log('续费脚本启动...', 'info')

    // 检查是否有未完成的续费
    const progressData = sessionStorage.getItem('hc_renewal_progress')
    if (progressData) {
      await continueRenewal()
    } else {
      await startRenewal()
    }
  }

  // --- Drag Functionality ---
  let isDragging = false
  let currentX = 0
  let currentY = 0
  let initialX = 0
  let initialY = 0

  const header = document.getElementById('hc-helper-header')

  function dragStart(e) {
    initialX = e.clientX - currentX
    initialY = e.clientY - currentY
    isDragging = true
  }

  function drag(e) {
    if (!isDragging) return
    e.preventDefault()
    currentX = e.clientX - initialX
    currentY = e.clientY - initialY
    panel.style.transform = `translate(${currentX}px, ${currentY}px)`
  }

  function dragEnd() {
    isDragging = false
  }

  header.addEventListener('mousedown', dragStart)
  document.addEventListener('mousemove', drag)
  document.addEventListener('mouseup', dragEnd)

  // --- Event Listeners ---
  startBtn.onclick = () => {
    if (isScanPage) {
      if (isScanning) {
        stopScan()
      } else {
        runScan()
      }
    }
    if (isRenewPage) {
      startBtn.disabled = true
      runRenewal()
    }
  }

  // --- Config Panel Event Listeners ---
  selectAllBtn.onclick = () => {
    const checkboxes = document.querySelectorAll('.hc-location-checkbox')
    checkboxes.forEach(cb => cb.classList.add('selected'))
    autoSaveLocations()
  }

  deselectAllBtn.onclick = () => {
    const checkboxes = document.querySelectorAll('.hc-location-checkbox')
    checkboxes.forEach(cb => cb.classList.remove('selected'))
    autoSaveLocations()
  }

  collapseBtn.onclick = toggleCollapse

  // Renewal option buttons event listeners
  renewalOptionBtns.forEach(btn => {
    btn.addEventListener('click', () => {
      selectRenewalOption(parseInt(btn.dataset.years))
    })
  })

  // Initialize config panel
  renderLocationCheckboxes()
  loadCollapseState()
  updateRenewalInfo()

  // 页面加载时检查是否有未完成的续费，并自动点击开始执行
  if (isRenewPage) {
    const progressData = sessionStorage.getItem('hc_renewal_progress')
    if (progressData) {
      const progress = JSON.parse(progressData)
      log(`检测到未完成的续费: ${progress.current}/${progress.total}`, 'info')
      log('自动继续续费流程...', 'info')
      
      // 自动点击开始执行按钮
      setTimeout(() => {
        if (startBtn && !startBtn.disabled) {
          startBtn.click()
        }
      }, 2000)
    } else {
      // 新的续费任务，也自动开始
      log('准备自动开始续费...', 'info')
      setTimeout(() => {
        if (startBtn && !startBtn.disabled) {
          log('自动点击"开始执行"按钮', 'info')
          startBtn.click()
        }
      }, 3000)
    }
  }

  // --- Invoice Auto-Payment Logic ---
  
  // 在发票列表页面：点击 Unpaid tab 并找到第一个发票（新窗口打开）
  // 然后定时检查是否支付完成
  if (isInvoicesListPage) {
    async function handleInvoicesList() {
      const currentUrl = window.location.href
      
      // 检查是否处于支付检查状态
      const isPaymentChecking = sessionStorage.getItem('hc_payment_checking') === 'true'
      const checkCount = parseInt(sessionStorage.getItem('hc_payment_check_count') || '0')
      const maxChecks = 120 // 最多检查10分钟
      
      if (isPaymentChecking) {
        // 正在检查支付状态
        const newCheckCount = checkCount + 1
        sessionStorage.setItem('hc_payment_check_count', newCheckCount.toString())
        
        log(`检查支付状态 (${newCheckCount}/${maxChecks})...`, 'info')
        await sleep(2000)
        
        // 检查是否还有未支付的发票
        const visibleContent = document.querySelector('table tbody') || document.body
        const unpaidInvoices = visibleContent.querySelectorAll('a[href*="/invoice/"]')
        
        if (unpaidInvoices.length === 0) {
          // 支付完成
          log('✅ 支付完成！未找到待支付发票', 'success')
          sessionStorage.removeItem('hc_payment_checking')
          sessionStorage.removeItem('hc_payment_check_count')
          
          // 检查续费进度
          const progressData = sessionStorage.getItem('hc_renewal_progress')
          if (progressData) {
            const progress = JSON.parse(progressData)
            if (progress.current < progress.total) {
              log(`继续下一轮续费 (${progress.current}/${progress.total})...`, 'info')
              await sleep(2000)
              const serviceIdMatch = currentUrl.match(/\/service\/(\d+)/)
              if (serviceIdMatch) {
                window.location.href = `https://dash.hidencloud.com/service/${serviceIdMatch[1]}/manage`
              }
            } else {
              log('🎉 所有续费和支付已完成！', 'success')
              sessionStorage.removeItem('hc_renewal_progress')
            }
          }
          return
        }
        
        if (newCheckCount >= maxChecks) {
          log('⏰ 支付检查超时，请手动确认', 'warn')
          sessionStorage.removeItem('hc_payment_checking')
          sessionStorage.removeItem('hc_payment_check_count')
          return
        }
        
        // 继续检查，5秒后刷新
        log(`仍有未支付发票，5秒后再次检查...`, 'info')
        setTimeout(() => {
          window.location.reload()
        }, 5000)
        return
      }
      
      // 首次进入发票列表页面
      log('在发票列表页面，准备处理...', 'info')
      await sleep(2000)
      
      // 确保在 unpaid tab - 如果不在，则重定向
      if (!currentUrl.includes('where=unpaid')) {
        log('检测到不在 Unpaid 页面，正在跳转...', 'info')
        const serviceIdMatch = currentUrl.match(/\/service\/(\d+)/)
        if (serviceIdMatch) {
          window.location.href = `https://dash.hidencloud.com/service/${serviceIdMatch[1]}/invoices?where=unpaid`
          return
        }
      }
      
      // 已经在 unpaid 页面，等待内容加载
      log('已在 Unpaid 页面，等待内容加载...', 'info')
      await sleep(3000)
      
      // 检查是否有未支付的发票
      async function checkAndProcessInvoice() {
        const visibleContent = document.querySelector('table tbody') || document.body
        let invoiceLink = visibleContent.querySelector('a[href*="/invoice/"]')
        
        if (!invoiceLink) {
          const allLinks = visibleContent.querySelectorAll('a')
          invoiceLink = Array.from(allLinks).find(link => {
            const text = link.textContent.trim()
            const isInvoiceLink = text.toLowerCase() === 'invoice' || text === 'Invoice'
            return isInvoiceLink && link.href && link.href.includes('/invoice/')
          })
        }
        
        if (!invoiceLink) {
          const allInvoiceLinks = document.querySelectorAll('a[href*="/invoice/"]')
          if (allInvoiceLinks.length > 0) {
            const visibleLinks = Array.from(allInvoiceLinks).filter(link => {
              const rect = link.getBoundingClientRect()
              return rect.width > 0 && rect.height > 0
            })
            if (visibleLinks.length > 0) {
              invoiceLink = visibleLinks[0]
            }
          }
        }
        
        return invoiceLink
      }
      
      // 查找第一个未支付发票
      let invoiceLink = await checkAndProcessInvoice()
      
      if (invoiceLink) {
        log('✅ 找到 Unpaid 发票链接！', 'success')
        log(`发票链接: ${invoiceLink.textContent.trim()} (${invoiceLink.href})`, 'info')
        log('发票将在新窗口打开，请在新窗口完成支付...', 'info')
        
        // 给链接添加 target="_blank" 确保在新窗口打开
        invoiceLink.setAttribute('target', '_blank')
        await sleep(1000)
        invoiceLink.click()
        
        // 开始定时检查支付状态（通过刷新页面）
        log('开始监控支付状态（每5秒检查一次）...', 'info')
        
        // 保存检查状态到 sessionStorage
        sessionStorage.setItem('hc_payment_checking', 'true')
        sessionStorage.setItem('hc_payment_check_count', '0')
        
        // 5秒后刷新页面进行检查
        setTimeout(() => {
          window.location.reload()
        }, 5000)
        
      } else {
        log('❌ 未找到 Unpaid 发票', 'warn')
        
        // 检查是否有续费进度
        const progressData = sessionStorage.getItem('hc_renewal_progress')
        if (progressData) {
          const progress = JSON.parse(progressData)
          if (progress.current < progress.total) {
            log('未找到待支付发票，返回续费页面继续...', 'info')
            await sleep(2000)
            const serviceIdMatch = currentUrl.match(/\/service\/(\d+)/)
            if (serviceIdMatch) {
              window.location.href = `https://dash.hidencloud.com/service/${serviceIdMatch[1]}/manage`
            }
          } else {
            log('🎉 续费流程已完成！', 'success')
            sessionStorage.removeItem('hc_renewal_progress')
          }
        }
      }
    }

    handleInvoicesList()
  }

  // 在发票详情页面：点击 Pay 按钮
  if (isInvoiceDetailPage) {
    async function handleInvoiceDetail() {
      log('✅ 已进入发票详情页面！', 'success')
      log('查找支付按钮...', 'info')
      await sleep(3000) // 等待页面完全加载
      
      // 查找 Pay 按钮（更精确的策略）
      let payButton = null
      
      // 策略1: 查找文本精确为 "Pay" 的按钮元素（button标签）
      const allButtons = document.querySelectorAll('button')
      payButton = Array.from(allButtons).find(btn => {
        const text = btn.textContent.trim()
        // 精确匹配 "Pay"，排除包含其他文本的元素
        return text === 'Pay' || text === 'pay' || text === '支付'
      })
      
      if (!payButton) {
        // 策略2: 查找绿色的Pay按钮（通过样式类）
        payButton = document.querySelector('button.bg-green-600, button.btn-success, button[class*="green"]')
        if (payButton) {
          const text = payButton.textContent.trim()
          if (text !== 'Pay' && !text.toLowerCase().startsWith('pay')) {
            payButton = null // 不是真正的Pay按钮
          }
        }
      }
      
      if (!payButton) {
        // 策略3: 在 "COMPLETE PAYMENT" 区域查找
        const paymentSection = Array.from(document.querySelectorAll('*')).find(el =>
          el.textContent.includes('COMPLETE PAYMENT')
        )
        if (paymentSection) {
          const buttons = paymentSection.querySelectorAll('button')
          payButton = Array.from(buttons).find(btn =>
            btn.textContent.trim() === 'Pay'
          )
        }
      }
      
      if (payButton) {
        log('✅ 找到支付按钮！', 'success')
        log(`按钮文本: "${payButton.textContent.trim()}"`, 'info')
        await sleep(1500)
        
        log('点击支付按钮...', 'info')
        payButton.click()
        
        // 等待支付处理
        await sleep(4000)
        log('✅ 支付请求已发送！', 'success')
        
        // 检查续费进度
        const progressData = sessionStorage.getItem('hc_renewal_progress')
        if (progressData) {
          const progress = JSON.parse(progressData)
          if (progress.current < progress.total) {
            log(`还需继续续费 (${progress.current}/${progress.total})`, 'info')
            log('返回续费页面继续流程...', 'info')
            await sleep(2000)
            
            // 从 referrer 提取 service ID
            if (document.referrer.includes('/service/')) {
              const referrerMatch = document.referrer.match(/\/service\/(\d+)/)
              if (referrerMatch) {
                const serviceId = referrerMatch[1]
                log(`返回服务 ${serviceId} 的管理页面...`, 'info')
                window.location.href = `https://dash.hidencloud.com/service/${serviceId}/manage`
              }
            } else {
              log('无法获取服务ID，尝试使用浏览器后退...', 'warn')
              window.history.go(-2) // 后退2页（发票详情 -> 发票列表 -> 管理页面）
            }
          } else {
            log('🎉 所有续费和支付已完成！', 'success')
            sessionStorage.removeItem('hc_renewal_progress')
          }
        } else {
          log('支付完成，无续费任务', 'info')
        }
      } else {
        log('❌ 未找到支付按钮', 'error')
        
        // 输出调试信息
        const allButtonsDebug = document.querySelectorAll('button')
        log(`调试: 页面共有 ${allButtonsDebug.length} 个 button 元素`, 'info')
        allButtonsDebug.forEach((btn, i) => {
          if (i < 5) { // 只显示前5个
            log(`  按钮 ${i+1}: "${btn.textContent.trim().substring(0, 50)}"`, 'info')
          }
        })
      }
    }

    handleInvoiceDetail()
  }
})()