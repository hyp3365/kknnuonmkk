// ==UserScript==
// @name         视频快进快退4.3
// @namespace    http://tampermonkey.net/
// @version      4.3
// @description  优化全屏布局修复，修复部分网站双击全屏后视频位移问题
// @author       Gemini & 哈哈 & 编码助手
// @match        *://*/*
// @grant        GM_registerMenuCommand
// @grant        GM_setValue
// @grant        GM_getValue
// @run-at       document-end
// ==/UserScript==

(function() {
    'use strict';

    // --- 样式修复：解决全屏偏移问题 ---
    const fixStyle = document.createElement('style');
    fixStyle.innerHTML = `
        /* 强制全屏容器内的视频居中且铺满 */
        :fullscreen video, :-webkit-full-screen video, :-moz-full-screen video {
            width: 100% !important;
            height: 100% !important;
            max-height: 100vh !important;
            object-fit: contain !important;
            margin: 0 auto !important;
        }
        /* 修复容器全屏后的黑色背景和对齐 */
        :fullscreen, :-webkit-full-screen, :-moz-full-screen {
            display: flex !important;
            align-items: center !important;
            justify-content: center !important;
            background-color: #000 !important;
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

    function toggleFullScreen(video) {
        if (!video) return;
        // 尝试寻找最合适的包装容器，避免只放大视频而丢失进度条
        const playerContainer = video.closest('.video-js, .player, [class*="player"], .video-container') || video.parentElement;
        const isFS = document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement;

        if (!isFS) {
            const requestFS = playerContainer.requestFullscreen || playerContainer.webkitRequestFullscreen || playerContainer.mozRequestFullScreen || playerContainer.msRequestFullscreen;
            if (requestFS) {
                requestFS.call(playerContainer).catch(() => {
                    // 如果容器全屏失败，尝试直接全屏视频
                    if (video.requestFullscreen) video.requestFullscreen();
                    else if (video.webkitEnterFullscreen) video.webkitEnterFullscreen();
                });
            } else if (video.webkitEnterFullscreen) {
                video.webkitEnterFullscreen();
            }
        } else {
            const exitFS = document.exitFullscreen || document.webkitExitFullscreen || document.mozCancelFullScreen || document.msExitFullscreen;
            if (exitFS) exitFS.call(document);
        }
    }

    // --- 自动播放逻辑 ---
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
            } else if (attempts >= 20) {
                clearInterval(playInterval);
            }
        }, 500);
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
                box-shadow: 0 0 20px rgba(0,0,0,0.5) !important;
                transition: opacity 0.15s !important;
                font-family: sans-serif !important;
                line-height: 1.2 !important;
            `;
        }
        let fsElement = document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement;
        let targetParent = fsElement;
        if (targetParent && ['VIDEO', 'IMG', 'IFRAME'].includes(targetParent.tagName)) {
            targetParent = targetParent.parentElement;
        }
        if (!targetParent) targetParent = document.body || document.documentElement;
        if (div.parentElement !== targetParent) {
            try { targetParent.appendChild(div); }
            catch (e) { if (document.body) document.body.appendChild(div); }
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

            const notice = getNoticeElement();
            notice.innerHTML = `
                <div style="font-size: 32px !important; margin-bottom: 8px !important;">${sign} ${Math.abs(actualSeek)}s</div>
                <div style="font-size: 18px !important;">${formatTime(targetTime)} / ${formatTime(currentVideo.duration)}</div>
            `;
            notice.style.display = 'block';
            notice.style.opacity = '1';
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

        const div = document.getElementById('slid-notice-v3');
        if (div) {
            div.style.opacity = '0';
            setTimeout(() => {
                if(!isSliding && div) div.style.display = 'none';
            }, 200);
        }
        isSliding = false;
    }, { capture: true });
})();
