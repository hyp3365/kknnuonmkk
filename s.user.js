// ==UserScript==
// @name         视频快进快退4.4
// @namespace    http://tampermonkey.net/
// @version      4.4
// @description  专项优化 XVideos 全屏位移问题，修复绝对定位导致的布局异常
// @author       Gemini & 哈哈 & 编码助手
// @match        *://*/*
// @grant        GM_registerMenuCommand
// @grant        GM_setValue
// @grant        GM_getValue
// @run-at       document-end
// ==/UserScript==

(function() {
    'use strict';

    // --- 样式修复：针对 XVideos 等站点的专项补丁 ---
    const fixStyle = document.createElement('style');
    fixStyle.innerHTML = `
        /* 1. 强制全屏容器布局 */
        :fullscreen, :-webkit-full-screen, :-moz-full-screen {
            display: flex !important;
            align-items: center !important;
            justify-content: center !important;
            background-color: #000 !important;
            width: 100vw !important;
            height: 100vh !important;
        }

        /* 2. 核心：重置视频定位。防止 XVideos 的 absolute 定位导致视频跑偏 */
        :fullscreen video, :-webkit-full-screen video, :-moz-full-screen video {
            position: relative !important; /* 关键：覆盖掉原本的 absolute */
            top: 0 !important;
            left: 0 !important;
            width: 100% !important;
            height: 100% !important;
            max-width: 100% !important;
            max-height: 100% !important;
            object-fit: contain !important;
            margin: auto !important;
        }

        /* 3. 针对 XVideos 特有的播放器容器覆盖 */
        #video-player-bg:fullscreen, .video-bg:fullscreen {
            padding: 0 !important;
            margin: 0 !important;
            overflow: hidden !important;
        }
    `;
    document.head.appendChild(fixStyle);

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
            if (!container) return null;
            const videos = Array.from(container.querySelectorAll('video'));
            const visibleVideos = videos.filter(v => v.offsetWidth > 0 && v.offsetHeight > 0);
            return visibleVideos.sort((a, b) => (b.offsetWidth * b.offsetHeight) - (a.offsetWidth * a.offsetHeight))[0];
        };

        // 1. 正在播放的优先
        const allVideos = Array.from(document.querySelectorAll('video'));
        const playingVideo = allVideos.find(v => !v.paused && v.currentTime > 0);
        if (playingVideo) return playingVideo;

        // 2. 目标元素所在的容器优先
        if (target) {
            if (target.tagName === 'VIDEO') return target;
            const container = target.closest('.video-js, .player, #player, .video-bg, [class*="player"]');
            const v = getLargestVideo(container);
            if (v) return v;
        }
        
        return getLargestVideo(document);
    }

    function toggleFullScreen(video) {
        if (!video) return;

        // XVideos 专项：它的外层容器 ID 通常是 video-player-bg
        const xVideosContainer = video.closest('#video-player-bg');
        const normalContainer = video.closest('.video-js, .player, [class*="player"], .video-container');
        const target = xVideosContainer || normalContainer || video.parentElement || video;

        const isFS = document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement;

        if (!isFS) {
            const requestFS = target.requestFullscreen || target.webkitRequestFullscreen || target.mozRequestFullScreen || target.msRequestFullscreen;
            if (requestFS) {
                requestFS.call(target).catch(() => {
                    // 保底方案：直接全屏 Video
                    video.requestFullscreen ? video.requestFullscreen() : video.webkitEnterFullscreen();
                });
            } else if (video.webkitEnterFullscreen) {
                video.webkitEnterFullscreen();
            }
        } else {
            const exitFS = document.exitFullscreen || document.webkitExitFullscreen || document.mozCancelFullScreen;
            if (exitFS) exitFS.call(document);
        }
    }

    // --- 自动播放 ---
    function tryAutoPlay() {
        let attempts = 0;
        const playInterval = setInterval(() => {
            attempts++;
            const video = findVideo(null);
            if (video && video.readyState >= 1) {
                if (video.paused) {
                    video.play().catch(() => {
                        video.muted = true;
                        video.play().catch(() => {});
                    });
                }
                clearInterval(playInterval);
            } else if (attempts >= 20) clearInterval(playInterval);
        }, 800);
    }
    tryAutoPlay();

    function getNoticeElement() {
        let div = document.getElementById('slid-notice-v3');
        if (!div) {
            div = document.createElement('div');
            div.id = 'slid-notice-v3';
            div.style.cssText = `
                position: fixed !important;
                top: 25% !important;
                left: 50% !important;
                transform: translate(-50%, -50%) !important;
                background-color: rgba(0, 0, 0, 0.85) !important;
                color: #FFD700 !important;
                padding: 15px 30px !important;
                border-radius: 20px !important;
                z-index: 2147483647 !important;
                pointer-events: none !important;
                font-size: 24px !important;
                font-weight: bold !important;
                display: none;
                text-align: center !important;
                transition: opacity 0.15s !important;
            `;
        }
        let fsElement = document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement;
        let targetParent = (fsElement && fsElement.tagName !== 'VIDEO') ? fsElement : (document.body || document.documentElement);
        if (div.parentElement !== targetParent) {
            try { targetParent.appendChild(div); } catch (e) {}
        }
        return div;
    }

    // 阻止点击穿透
    const stopEvent = (e) => { if (blockClick) { e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation(); } };
    window.addEventListener('click', stopEvent, { capture: true });
    window.addEventListener('mouseup', stopEvent, { capture: true });

    window.addEventListener('touchstart', function(e) {
        if (e.target && e.target.tagName === 'INPUT') return;
        
        currentVideo = findVideo(e.target);
        if (!currentVideo) return;

        startX = e.touches[0].clientX;
        startY = e.touches[0].clientY;
        baseTime = currentVideo.currentTime;
        isSliding = false;

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
        if (!config.enableSlide || !currentVideo || isNaN(currentVideo.duration)) return;
        const moveX = e.touches[0].clientX - startX;
        const moveY = e.touches[0].clientY - startY;

        if (!isSliding && Math.abs(moveX) > startThreshold && Math.abs(moveX) > Math.abs(moveY)) {
            isSliding = true;
        }

        if (isSliding) {
            if (e.cancelable) e.preventDefault();
            seekAmount = Math.floor(moveX / sensitivity);
            let targetTime = Math.max(0, Math.min(baseTime + seekAmount, currentVideo.duration));
            const actualSeek = Math.floor(targetTime - baseTime);
            
            const notice = getNoticeElement();
            notice.innerHTML = `<div style="font-size:32px;">${actualSeek >= 0 ? "⏩" : "⏪"} ${Math.abs(actualSeek)}s</div>
                                <div style="font-size:18px;">${formatTime(targetTime)} / ${formatTime(currentVideo.duration)}</div>`;
            notice.style.display = 'block';
            notice.style.opacity = '1';
        }
    }, { passive: false, capture: true });

    window.addEventListener('touchend', function(e) {
        if (isSliding && currentVideo) {
            if (e.cancelable) e.preventDefault();
            blockClick = true;
            clearTimeout(blockTimeout);
            blockTimeout = setTimeout(() => { blockClick = false; }, 400);
            currentVideo.currentTime = Math.max(0, Math.min(currentVideo.currentTime + seekAmount, currentVideo.duration));
        }
        const div = document.getElementById('slid-notice-v3');
        if (div) { div.style.opacity = '0'; setTimeout(() => { if(!isSliding) div.style.display = 'none'; }, 200); }
        isSliding = false;
    }, { capture: true });
})();
