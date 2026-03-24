// ==UserScript==
// @name         视频快进快退4.3 (YouTube 终极修复版)
// @namespace    http://tampermonkey.net/
// @version      4.3
// @description  彻底重构定位逻辑，解决YouTube等复杂播放器提示框不可见问题
// @author       Gemini & 哈哈 & 编码助手
// @match        *://*/*
// @grant        GM_registerMenuCommand
// @grant        GM_setValue
// @grant        GM_getValue
// @run-at       document-end
// ==/UserScript==

(function() {
    'use strict';

    const host = location.hostname;
    const SLIDE_KEY = 'enableSlide_' + host;
    const CLICK_KEY = 'enableDoubleClick_' + host;

    let config = {
        enableSlide: GM_getValue(SLIDE_KEY, true),
        enableDoubleClick: GM_getValue(CLICK_KEY, true)
    };

    GM_registerMenuCommand(config.enableSlide ? '🟢 快进快退：已启用' : '⚪ 快进快退：未启用', () => {
        GM_setValue(SLIDE_KEY, !config.enableSlide);
        location.reload();
    });

    GM_registerMenuCommand(config.enableDoubleClick ? '🟢 双击全屏：已启用' : '⚪ 双击全屏：未启用', () => {
        GM_setValue(CLICK_KEY, !config.enableDoubleClick);
        location.reload();
    });

    const sensitivity = 4;
    const startThreshold = 8;
    const tapDelay = 300;

    let lastTapTime = 0;
    let startX = 0, startY = 0;
    let isSliding = false;
    let currentVideo = null;
    let seekAmount = 0;
    let baseTime = 0;
    let blockClick = false;
    let blockTimeout = null;

    function formatTime(seconds) {
        if (isNaN(seconds) || seconds === Infinity) return "LIVE";
        const h = Math.floor(seconds / 3600);
        const m = Math.floor((seconds % 3600) / 60);
        const s = Math.floor(seconds % 60);
        return h > 0 ?
            `${h}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}` :
            `${m}:${s.toString().padStart(2, '0')}`;
    }

    function findVideo(target) {
        const getLargestVideo = (container) => {
            const videos = Array.from(container.querySelectorAll('video'));
            if (videos.length === 0) return null;
            const visibleVideos = videos.filter(v => v.offsetWidth > 0 && v.offsetHeight > 0);
            if (visibleVideos.length === 0) return null;
            return visibleVideos.sort((a, b) => (b.offsetWidth * b.offsetHeight) - (a.offsetWidth * a.offsetHeight))[0];
        };
        const allVideos = Array.from(document.querySelectorAll('video'));
        const playingVideo = allVideos.find(v => !v.paused && v.currentTime > 0 && v.offsetWidth > 0);
        if (playingVideo) return playingVideo;
        const fsElement = document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement;
        if (fsElement) {
            if (fsElement.tagName === 'VIDEO') return fsElement;
            const fsVideo = getLargestVideo(fsElement);
            if (fsVideo) return fsVideo;
        }
        if (target && target.tagName === 'VIDEO') return target;
        const container = target ? target.closest('.video-js, .player, #player, .video-container, [class*="player"], [class*="video"], div[id*="player"]') : null;
        if (container) {
            const v = getLargestVideo(container);
            if (v) return v;
        }
        return getLargestVideo(document);
    }

    // 核心修改区：重构弹窗元素获取与定位逻辑
    function getNoticeElement(videoElement) {
        // 升级 ID 防止被旧版脚本缓存干扰
        let div = document.getElementById('slid-notice-v4');
        if (!div) {
            div = document.createElement('div');
            div.id = 'slid-notice-v4';
            // 改用 position: absolute 并调整样式，适应相对定位
            div.style.cssText = `
                position: absolute !important; 
                top: 25% !important;
                left: 50% !important;
                transform: translate(-50%, -50%) !important;
                background-color: rgba(0, 0, 0, 0.75) !important;
                color: #FFF !important;
                padding: 12px 24px !important;
                border-radius: 12px !important;
                z-index: 2147483647 !important;
                pointer-events: none !important;
                font-family: Arial, sans-serif !important;
                display: none;
                text-align: center !important;
                text-shadow: 1px 1px 2px #000 !important;
                box-shadow: 0 4px 12px rgba(0,0,0,0.4) !important;
                transition: opacity 0.15s !important;
                line-height: 1.5 !important;
                white-space: nowrap !important;
                letter-spacing: normal !important;
            `;
        }
        
        let targetParent = null;
        const fsElement = document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement;
        
        // 1. 如果在全屏下，优先挂载到全屏容器
        if (fsElement) {
            targetParent = ['VIDEO', 'IMG', 'IFRAME'].includes(fsElement.tagName) ? fsElement.parentElement : fsElement;
        } 
        // 2. 否则，精准狙击 YouTube 等网站的播放器主容器
        else if (videoElement) {
            targetParent = videoElement.closest('.html5-video-player, #movie_player, #player-container-inner, .video-js, .player') || videoElement.parentElement;
        }

        // 3. 终极保底
        if (!targetParent) targetParent = document.body;

        // 强制确保父容器具备定位上下文，否则 absolute 定位会乱飞
        if (targetParent !== document.body) {
            const parentPosition = window.getComputedStyle(targetParent).position;
            if (parentPosition === 'static') {
                targetParent.style.setProperty('position', 'relative', 'important');
            }
        }

        // 插入节点
        if (div.parentElement !== targetParent) {
            try { targetParent.appendChild(div); }
            catch (e) { document.body.appendChild(div); }
        }
        return div;
    }

    const stopEvent = (e) => {
        if (blockClick) {
            e.preventDefault();
            e.stopPropagation();
            e.stopImmediatePropagation();
        }
    };

    window.addEventListener('click', stopEvent, { capture: true });
    window.addEventListener('mouseup', stopEvent, { capture: true });
    window.addEventListener('pointerup', stopEvent, { capture: true });

    window.addEventListener('touchstart', function(e) {
        if (e.target) {
            const cls = (typeof e.target.className === 'string') ? e.target.className.toLowerCase() : '';
            const idName = (typeof e.target.id === 'string') ? e.target.id.toLowerCase() : '';
            if (
                cls.includes('progress') || cls.includes('slider') || cls.includes('thumb') || cls.includes('bar') ||
                idName.includes('progress') || idName.includes('slider') || idName.includes('thumb') || idName.includes('bar') ||
                e.target.tagName === 'INPUT'
            ) return;
        }
        currentVideo = findVideo(e.target);
        if (!currentVideo) return;

        startX = e.touches[0].clientX;
        startY = e.touches[0].clientY;
        baseTime = currentVideo.currentTime;
        isSliding = false;
        seekAmount = 0;

        const now = Date.now();
        if (config.enableDoubleClick && (now - lastTapTime < tapDelay)) {
            if (e.cancelable) e.preventDefault();
            toggleFullScreen(currentVideo);
            lastTapTime = 0;
        } else {
            lastTapTime = now;
        }
    }, { passive: false, capture: true });

    window.addEventListener('touchmove', function(e) {
        if (!config.enableSlide || !currentVideo) return;
        if (currentVideo.duration === Infinity || isNaN(currentVideo.duration)) return;

        const moveX = e.touches[0].clientX - startX;
        const moveY = e.touches[0].clientY - startY;

        if (!isSliding && Math.abs(moveX) > startThreshold && Math.abs(moveX) > Math.abs(moveY)) {
            isSliding = true;
        }

        if (isSliding) {
            if (e.cancelable) e.preventDefault();
            seekAmount = Math.floor(moveX / sensitivity);
            let targetTime = baseTime + seekAmount;
            targetTime = Math.max(0, Math.min(targetTime, currentVideo.duration));
            const actualSeek = Math.floor(targetTime - baseTime);
            const sign = actualSeek >= 0 ? "⏩" : "⏪";

            const notice = getNoticeElement(currentVideo);
            notice.innerHTML = `
                <div style="font-size: 28px !important; font-weight: bold !important; margin-bottom: 5px !important; color: #FFD700 !important;">${sign} ${Math.abs(actualSeek)}s</div>
                <div style="font-size: 16px !important; font-weight: normal !important; color: #FFFFFF !important;">${formatTime(targetTime)} / ${formatTime(currentVideo.duration)}</div>
            `;
            notice.style.setProperty('display', 'block', 'important');
            notice.style.setProperty('opacity', '1', 'important');
        }
    }, { passive: false, capture: true });

    window.addEventListener('touchend', function(e) {
        if (isSliding && currentVideo && currentVideo.duration !== Infinity && !isNaN(currentVideo.duration)) {
            if (e.cancelable) e.preventDefault();
            e.stopImmediatePropagation();
            blockClick = true;
            clearTimeout(blockTimeout);
            blockTimeout = setTimeout(() => { blockClick = false; }, 400);
            let targetTime = currentVideo.currentTime + seekAmount;
            currentVideo.currentTime = Math.max(0, Math.min(targetTime, currentVideo.duration));
        }

        const div = document.getElementById('slid-notice-v4');
        if (div) {
            div.style.setProperty('opacity', '0', 'important');
            setTimeout(() => {
                if(!isSliding && div) div.style.setProperty('display', 'none', 'important');
            }, 150);
        }
        isSliding = false;
    }, { capture: true });

    function toggleFullScreen(video) {
        const playerContainer = video.closest('.video-js, .player, [class*="player"]') || video.parentElement;
        if (!document.fullscreenElement && !document.webkitFullscreenElement && !document.mozFullScreenElement) {
            if (playerContainer.requestFullscreen) playerContainer.requestFullscreen();
            else if (playerContainer.webkitRequestFullscreen) playerContainer.webkitRequestFullscreen();
            else if (video.webkitEnterFullscreen) video.webkitEnterFullscreen();
        } else {
            if (document.exitFullscreen) document.exitFullscreen();
            else if (document.webkitExitFullscreen) document.webkitExitFullscreen();
        }
    }
})();
