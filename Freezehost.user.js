// ==UserScript==
// @name         Freezehost 极致拟人稳定版 v27.0
// @namespace    http://tampermonkey.net/
// @version      27.0
// @match        *://*.freezehost.pro/earn*
// @grant        none
// ==/UserScript==

(function() {
    'use strict';

    let lT = "";
    let sC = 0;
    let bL = false;
    let cC = 0;
    let nS = Math.floor(Math.random() * 6) + 5;
    let aC = 0;
    let wA = false;

    function mC(e) {
        if (!e) return;
        const r = e.getBoundingClientRect();
        const x = r.left + 5 + Math.random() * (r.width - 10);
        const y = r.top + 5 + Math.random() * (r.height - 10);
        ['mouseenter', 'mousedown', 'mouseup', 'click'].forEach(t => {
            e.dispatchEvent(new MouseEvent(t, { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y }));
        });
    }

    function fA() {
        if (wA) return true;

        const k = ["CLOSE", "DISMISS", "关闭", "×", "X"];
        document.querySelectorAll('button, a, div, span, i').forEach(e => {
            const t = e.innerText.trim().toUpperCase();
            if (e.offsetWidth > 0 && e.offsetWidth < 100 && k.includes(t)) {
                const s = window.getComputedStyle(e);
                if (parseInt(s.zIndex) > 10 || s.position === 'fixed') mC(e);
            }
        });
        
        document.querySelectorAll('#dismiss-button, [aria-label*="Close"], [aria-label*="close"]').forEach(e => {
            if (e.offsetWidth > 0) mC(e);
        });

        const b = document.body.innerText.toUpperCase();
        if (b.includes("UNLOCK MORE CONTENT") || b.includes("VIEW A SHORT AD")) {
            aC++;
            if (aC >= 2) {
                bL = true;
                wA = true;
                let tgt = Array.from(document.querySelectorAll('div, span')).find(e => e.innerText && e.innerText.trim().toUpperCase() === "VIEW A SHORT AD");
                if (tgt && tgt.parentElement) {
                    mC(tgt.parentElement);
                } else {
                    tgt = Array.from(document.querySelectorAll('*')).find(e => e.innerText && e.innerText.toUpperCase().includes("VIEW A SHORT AD") && e.children.length < 3);
                    if (tgt) mC(tgt);
                }
                
                setTimeout(() => {
                    wA = false;
                    bL = false;
                    aC = 0;
                    p(); 
                }, 60000);
                return true;
            }
        } else {
            aC = 0;
        }
        return false;
    }

    function p() {
        if (bL || wA) return;

        if (fA()) return;

        const b = document.body.innerText;
        const rD = Math.floor(Math.random() * 2001) + 3000;
        const cD = Math.floor(Math.random() * 5001) + 10000;
        const nD = Math.floor(Math.random() * 5001) + 10000;

        if (cC >= nS) {
            const sD = Math.floor(Math.random() * 41) + 10;
            const dir = Math.random() > 0.5 ? 1 : -1;
            const sV = sD * dir;
            window.scrollBy({ top: sV, behavior: 'smooth' });
            setTimeout(() => { window.scrollBy({ top: -sV, behavior: 'smooth' }); }, 600);
            cC = 0;
            nS = Math.floor(Math.random() * 6) + 5;
        } else {
            cC++;
        }

        if (/Session Time Remaining\s*0:00/i.test(b)) {
            bL = true;
            setTimeout(() => { location.reload(); }, rD);
            return;
        }

        const tm = b.match(/(\d{1,2}:\d{2})/);
        if (tm) {
            const cT = tm[1];
            if (cT === lT) {
                sC++;
            } else {
                sC = 0;
                lT = cT;
            }

            if (sC >= 3) {
                bL = true;
                setTimeout(() => { location.reload(); }, rD);
                return;
            }
        } else {
            const btn = Array.from(document.querySelectorAll('button, a, .btn'))
                             .find(el => el.innerText.toUpperCase().includes("AFK") && el.offsetWidth > 0);
            if (btn) {
                bL = true;
                setTimeout(() => {
                    mC(btn);
                    bL = false;
                    lT = "";
                    sC = 0;
                    setTimeout(p, nD);
                }, cD);
                return;
            }
        }

        setTimeout(p, nD);
    }

    setTimeout(p, Math.floor(Math.random() * 5001) + 10000);

})();
