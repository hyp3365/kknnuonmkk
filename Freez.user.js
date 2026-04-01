// ==UserScript==
// @name         FreezeHost AFK 自动挂机 (v20 双重防冻版)
// @namespace    http://tampermonkey.net/
// @version      20.0
// @description  Web Worker + 静音音频双重防冻，彻底解决后台标签页节流问题
// @author       Claude
// @match        https://free.freezehost.pro/earn
// @grant        none
// ==/UserScript==

(function () {
    'use strict';

    const CFG = {
        CHECK_INTERVAL: 1000,
        FORCE_REFRESH:  3600 * 1000,
        CLICK_DEBOUNCE: 3000,
    };

    // ── 防冻第一层：Web Worker 计时 ──────────────────────────────────
    const workerCode = `
        let iv = null;
        self.onmessage = function(e) {
            if (e.data === 'start') { if (!iv) iv = setInterval(() => self.postMessage('tick'), 1000); }
            else if (e.data === 'stop') { clearInterval(iv); iv = null; }
        };
    `;
    const worker = new Worker(URL.createObjectURL(new Blob([workerCode], { type: 'application/javascript' })));

    const startTime = Date.now();
    let lastClickTime = 0;
    let tickCount = 0;

    // ── UI 面板 ──────────────────────────────────────────────────────
    const panel = document.createElement('div');
    panel.id = 'afk-panel';
    panel.style.cssText = [
        'position:fixed','bottom:20px','right:20px','z-index:2147483647',
        'width:280px',
        'background:linear-gradient(145deg,#0f0f1a,#1a1a2e)',
        'border:1px solid rgba(100,100,255,0.3)',
        'border-radius:14px',
        'box-shadow:0 8px 32px rgba(0,0,0,0.6),0 0 0 1px rgba(255,255,255,0.05)',
        "font-family:'Consolas','Monaco',monospace",
        'font-size:12px','color:#e0e0e0','overflow:hidden','user-select:none',
    ].join(';');

    panel.innerHTML = [
        '<div id="afk-header" style="background:rgba(255,255,255,0.05);padding:10px 14px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid rgba(255,255,255,0.07);cursor:move;">',
        '  <span style="font-size:13px;font-weight:bold;color:#7eb3ff;">&#129302; FreezeHost AFK v20</span>',
        '  <span id="afk-uptime" style="font-size:11px;background:rgba(255,255,255,0.08);padding:2px 8px;border-radius:10px;color:#aaa;">0分0秒</span>',
        '</div>',
        '<div style="padding:12px 14px;display:flex;flex-direction:column;gap:8px;">',
        '  <div id="afk-status-row" style="display:flex;align-items:center;gap:8px;padding:8px 10px;background:rgba(255,255,255,0.04);border-radius:8px;border-left:3px solid #888;">',
        '    <span id="afk-dot" style="width:8px;height:8px;border-radius:50%;background:#888;flex-shrink:0;box-shadow:0 0 6px #888;"></span>',
        '    <div style="flex:1;min-width:0;">',
        '      <div id="afk-status-title" style="font-weight:bold;font-size:12px;color:#fff;">初始化中...</div>',
        '      <div id="afk-status-detail" style="font-size:11px;color:#999;margin-top:1px;">加载页面元素...</div>',
        '    </div>',
        '  </div>',
        '  <div style="display:flex;gap:8px;">',
        '    <div style="flex:1;padding:7px 10px;background:rgba(255,255,255,0.04);border-radius:8px;text-align:center;">',
        '      <div style="color:#aaa;font-size:10px;margin-bottom:2px;">SESSION 倒计时</div>',
        '      <div id="afk-timer" style="color:#7eb3ff;font-size:14px;font-weight:bold;">--:--</div>',
        '    </div>',
        '    <div style="flex:1;padding:7px 10px;background:rgba(255,255,255,0.04);border-radius:8px;text-align:center;">',
        '      <div style="color:#aaa;font-size:10px;margin-bottom:2px;">刷新倒计时</div>',
        '      <div id="afk-refresh" style="color:#ffd700;font-size:14px;font-weight:bold;">--:--</div>',
        '    </div>',
        '  </div>',
        '  <div style="padding:7px 10px;background:rgba(255,255,255,0.04);border-radius:8px;display:flex;justify-content:space-between;align-items:center;">',
        '    <span style="color:#aaa;font-size:11px;">&#128421; 标签页</span>',
        '    <span id="afk-bg-status" style="font-size:11px;padding:2px 8px;border-radius:10px;background:rgba(0,200,100,0.15);color:#00cc66;">前台运行</span>',
        '  </div>',
        '  <div style="padding:7px 10px;background:rgba(255,255,255,0.04);border-radius:8px;display:flex;justify-content:space-between;">',
        '    <span style="color:#aaa;font-size:11px;">&#9889; Worker 心跳</span>',
        '    <span id="afk-tick" style="color:#7eb3ff;font-size:11px;">0 次</span>',
        '  </div>',
        '  <div style="padding:7px 10px;background:rgba(255,255,255,0.04);border-radius:8px;display:flex;justify-content:space-between;align-items:center;">',
        '    <span style="color:#aaa;font-size:11px;">&#128263; 静音防冻</span>',
        '    <span id="afk-audio-status" style="font-size:11px;padding:2px 8px;border-radius:10px;background:rgba(255,170,0,0.15);color:#ffaa00;">等待激活</span>',
        '  </div>',
        '</div>',
    ].join('');

    document.body.appendChild(panel);

    // 拖动
    let dragging = false, ox = 0, oy = 0;
    document.getElementById('afk-header').addEventListener('mousedown', e => {
        dragging = true;
        const r = panel.getBoundingClientRect();
        ox = e.clientX - r.left; oy = e.clientY - r.top;
    });
    document.addEventListener('mousemove', e => {
        if (!dragging) return;
        panel.style.right = 'auto'; panel.style.bottom = 'auto';
        panel.style.left = (e.clientX - ox) + 'px';
        panel.style.top  = (e.clientY - oy) + 'px';
    });
    document.addEventListener('mouseup', () => dragging = false);

    // ── 防冻第二层：静音音频 ─────────────────────────────────────────
    // DOM 已完全就绪，afk-audio-status 元素已存在，可以安全操作
    // 使用捕获阶段（true）监听，不会被任何子元素的事件拦截
    (function startSilentAudio() {
        try {
            const AudioCtx = window.AudioContext || window.webkitAudioContext;
            if (!AudioCtx) throw new Error('不支持 AudioContext');

            const ctx    = new AudioCtx();
            const buffer = ctx.createBuffer(1, ctx.sampleRate * 0.5, ctx.sampleRate);
            const gain   = ctx.createGain();
            gain.gain.value = 0;
            gain.connect(ctx.destination);

            function playLoop() {
                const src = ctx.createBufferSource();
                src.buffer  = buffer;
                src.connect(gain);
                src.onended = playLoop;
                src.start();
            }

            function setUI(active) {
                const el = document.getElementById('afk-audio-status');
                if (!el) return;
                el.textContent       = active ? '静音音频 \u2713' : '等待激活';
                el.style.color       = active ? '#00cc66' : '#ffaa00';
                el.style.background  = active ? 'rgba(0,200,100,0.15)' : 'rgba(255,170,0,0.15)';
            }

            function activate() {
                ctx.resume().then(() => {
                    playLoop();
                    setUI(true);
                    console.log('[AFKv20] 静音音频已激活，state:', ctx.state);
                    document.removeEventListener('click',   activate, true);
                    document.removeEventListener('keydown', activate, true);
                }).catch(err => console.warn('[AFKv20] resume 失败:', err));
            }

            console.log('[AFKv20] AudioContext 初始 state:', ctx.state);

            if (ctx.state === 'running') {
                playLoop();
                setUI(true);
                console.log('[AFKv20] 静音音频直接启动');
            } else {
                document.addEventListener('click',   activate, true);
                document.addEventListener('keydown', activate, true);
                console.log('[AFKv20] 等待用户交互以激活音频...');
            }

        } catch (err) {
            console.warn('[AFKv20] 静音音频不可用:', err);
        }
    })();

    // ── UI 工具 ──────────────────────────────────────────────────────
    function formatMs(ms) {
        if (ms <= 0) return '0分0秒';
        const s = Math.floor(ms / 1000);
        return Math.floor(s / 60) + '分' + (s % 60) + '秒';
    }

    function pad2(n) { return String(n).padStart(2, '0'); }

    function formatCountdown(ms) {
        if (ms <= 0) return '00:00';
        const s = Math.floor(ms / 1000);
        return pad2(Math.floor(s / 60)) + ':' + pad2(s % 60);
    }

    const STATUS = {
        running: { color:'#00ccff', title:'\ud83d\udcb0 稳定挂机中'    },
        renew:   { color:'#ff66ff', title:'\ud83d\udd04 Session 续期'  },
        start:   { color:'#00ff88', title:'\ud83d\ude80 准备 / 断线重连'},
        stuck:   { color:'#ff4444', title:'\u26a0\ufe0f 倒计时卡死'    },
        refresh: { color:'#ff8800', title:'\u267b\ufe0f 定时强制刷新'  },
        loading: { color:'#888888', title:'\u23f3 页面加载中'          },
    };

    function updateUI(key, detail, timerText) {
        const s = STATUS[key] || STATUS.loading;
        const row = document.getElementById('afk-status-row');
        const dot = document.getElementById('afk-dot');
        row.style.borderLeftColor = s.color;
        dot.style.background  = s.color;
        dot.style.boxShadow   = '0 0 6px ' + s.color;
        document.getElementById('afk-status-title').textContent  = s.title;
        document.getElementById('afk-status-detail').textContent = detail;
        document.getElementById('afk-timer').textContent  = timerText || '--:--';
        document.getElementById('afk-tick').textContent   = tickCount + ' 次';

        const elapsed   = Date.now() - startTime;
        const remaining = CFG.FORCE_REFRESH - elapsed;
        document.getElementById('afk-uptime').textContent  = formatMs(elapsed);
        document.getElementById('afk-refresh').textContent = formatCountdown(remaining);

        const bgEl  = document.getElementById('afk-bg-status');
        const hidden = document.hidden;
        bgEl.textContent      = hidden ? '后台运行 \u2713' : '前台运行';
        bgEl.style.color      = hidden ? '#8888ff' : '#00cc66';
        bgEl.style.background = hidden ? 'rgba(100,100,255,0.15)' : 'rgba(0,200,100,0.15)';
    }

    // ── 点击（带防抖）────────────────────────────────────────────────
    function tryClick(el, name) {
        if (Date.now() - lastClickTime < CFG.CLICK_DEBOUNCE) return false;
        lastClickTime = Date.now();
        console.log('[AFKv20] 点击:', name);
        const opts = { bubbles:true, cancelable:true, view:window };
        el.dispatchEvent(new MouseEvent('mousedown', opts));
        el.dispatchEvent(new MouseEvent('mouseup', opts));
        el.click();
        const orig = el.style.outline;
        el.style.outline = '2px solid #fff';
        setTimeout(() => { el.style.outline = orig; }, 400);
        return true;
    }

    function getRenewBtn() {
        return document.evaluate(
            "//button[contains(.,'Start New Session')]",
            document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null
        ).singleNodeValue;
    }

    // ── 主循环 ───────────────────────────────────────────────────────
    function loop() {
        tickCount++;
        const remaining = CFG.FORCE_REFRESH - (Date.now() - startTime);

        if (remaining <= 0) {
            updateUI('refresh', '运行满1小时，执行刷新...', '--:--');
            worker.postMessage('stop');
            setTimeout(() => location.reload(), 500);
            return;
        }

        const bodyText  = document.body.innerText;
        const startBtn  = document.getElementById('start-afk-btn');
        const timerEl   = document.getElementById('session-timer');
        const timerText = timerEl ? timerEl.innerText.trim() : '';

        if (timerText === '0:00' || timerText === '00:00') {
            updateUI('stuck', '检测到 0:00 卡死，尝试续期...', timerText);
            const btn = getRenewBtn();
            if (btn) tryClick(btn, 'Start New Session (stuck)');
            else setTimeout(() => location.reload(), 2000);
            return;
        }

        const renewBtn = getRenewBtn();
        if (renewBtn && renewBtn.offsetParent !== null) {
            updateUI('renew', 'Session 结束，点击续期', timerText);
            tryClick(renewBtn, 'Start New Session');
            return;
        }

        if (bodyText.includes('You are now earning coins') || bodyText.includes('1 coin will be added')) {
            updateUI('running', '正在获取金币，倒计时: ' + timerText, timerText);
            return;
        }

        if (startBtn) {
            updateUI('start', '检测到空闲，点击开始', timerText);
            tryClick(startBtn, 'Start AFK Session');
            return;
        }

        updateUI('loading', '等待按钮出现...', timerText);
    }

    // ── 启动 ─────────────────────────────────────────────────────────
    worker.onmessage = () => loop();
    worker.postMessage('start');

    document.addEventListener('visibilitychange', () => {
        console.log('[AFKv20] 标签页:', document.hidden ? '后台' : '前台');
    });

    console.log('[AFKv20] 双重防冻版已启动');
    loop();

})();
