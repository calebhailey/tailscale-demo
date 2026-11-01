class CountDown extends HTMLElement {
    static observedAttributes = ["until"];

    connectedCallback() {
        this.setAttribute("role", "timer");
        this.start();
    }

    disconnectedCallback() {
        clearInterval(this.timer);
    }

    attributeChangedCallback() {
        if (this.isConnected) this.start();
    }

    start() {
        clearInterval(this.timer);
        this.deadline = Date.parse(this.getAttribute("until"));
        this.finished = false;
        this.render();
        this.timer = setInterval(() => this.render(), 250);
    }

    render() {
        const seconds = Number.isFinite(this.deadline)
            ? Math.max(0, Math.ceil((this.deadline - Date.now()) / 1000))
            : 0;
        const minutes = Math.floor(seconds / 60);
        this.textContent = `${String(minutes).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
        this.setAttribute("aria-label", `${seconds} seconds until session expiry`);

        if (seconds === 0) {
            clearInterval(this.timer);
            if (!this.finished) {
                this.finished = true;
                this.dispatchEvent(new Event("countdowncomplete"));
            }
        }
    }
}

customElements.define("count-down", CountDown);
