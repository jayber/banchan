import Quill from "quill";
import TurndownService from "turndown";
import Marked from "marked";

console.log(Quill);

let QuillInput = {
  mounted() {
    this.initEditor();
    let dragCounter = 0;

    this.ondragenter = document.addEventListener("dragenter", e => {
      e.preventDefault();
      e.stopPropagation();
      dragCounter += 1;
      if (e.dataTransfer.types.includes("Files") || e.dataTransfer.types.includes("application/x-moz-file")) {
        this.pushEventTo(this.el, "dragstart", {});
      }
    });

    this.ondragover = document.addEventListener("dragover", e => {
      e.dataTransfer.dropEffect = "none";
      if (e.dataTransfer.types.includes("Files") || e.dataTransfer.types.includes("application/x-moz-file")) {
        e.dataTransfer.dropEffect = "copy";
      }
    });

    this.ondragleave = document.addEventListener("dragleave", e => {
      e.preventDefault();
      e.stopPropagation();

      dragCounter -= 1;

      if (dragCounter <= 1) {
        this.pushEventTo(this.el, "dragend", {});
      }
    });

    this.ondrop = document.addEventListener("drop", e => {
      dragCounter -= 1;
      this.pushEventTo(this.el, "dragend", {});
    });
  },

  destroyed() {
    document.removeEventListener("dragenter", this.ondragenter);
    document.removeEventListener("dragover", this.ondragover);
    document.removeEventListener("dragleave", this.ondragleave);
    document.removeEventListener("drop", this.ondrop);
    this.editor.destroy();
  },

  initEditor() {
    const el = this.el.querySelector(".editor");
    this.editor = new Quill(el);

    // this.handleEvent("clear-markdown-input", ({ id }) => {
    //   if (id == this.el.id && !!this.editor.getMarkdown()) {
    //     this.updatingFromTextarea = true;
    //     this.editor.setMarkdown("");
    //     this.updatingFromTextarea = false;
    //   }
    // });

    this.handleEvent(`markdown-updated`, msg => {
      if (msg.id == this.el.id && msg.value !== this.editor.getMarkdown() && !this.changedSinceLastUpdate) {
        this.el.querySelector(".input-textarea").value = msg.value || "";
        this.editor.setMarkdown(msg.value || "");
      }
    });
  }
};

export { QuillInput };
