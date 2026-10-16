'use strict';
// LSP base-protocol framing ("Content-Length: n\r\n\r\n<json>") and the line-delimited form the Linter server speaks.

/** Incremental parser: feed(chunk) returns the complete messages found so far. Bad frames are skipped, never thrown. */
class FrameParser {
	constructor(onError) {
		this.buffer = Buffer.alloc(0);
		this.onError = onError || (() => {});
	}

	feed(chunk) {
		this.buffer = this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk]);
		const messages = [];
		for (;;) {
			const headerEnd = this.buffer.indexOf('\r\n\r\n');
			if (headerEnd < 0) break;
			const header = this.buffer.subarray(0, headerEnd).toString('ascii');
			const match = /Content-Length:\s*(\d+)/i.exec(header);
			if (!match) {
				this.onError(new Error('frame without Content-Length'));
				this.buffer = this.buffer.subarray(headerEnd + 4);
				continue;
			}
			const length = Number(match[1]);
			const start = headerEnd + 4;
			if (this.buffer.length < start + length) break;
			const body = this.buffer.subarray(start, start + length).toString('utf8');
			this.buffer = this.buffer.subarray(start + length);
			try {
				messages.push(JSON.parse(body));
			} catch (error) {
				this.onError(error);
			}
		}
		return messages;
	}
}

/** Incremental parser for one JSON message per line. */
class LineParser {
	constructor(onError) {
		this.text = '';
		this.onError = onError || (() => {});
	}

	feed(chunk) {
		this.text += chunk.toString('utf8');
		const messages = [];
		let newline;
		while ((newline = this.text.indexOf('\n')) >= 0) {
			const line = this.text.slice(0, newline).trim();
			this.text = this.text.slice(newline + 1);
			if (!line) continue;
			try {
				messages.push(JSON.parse(line));
			} catch (error) {
				this.onError(error);
			}
		}
		return messages;
	}
}

function encodeFrame(message) {
	const body = Buffer.from(JSON.stringify(message), 'utf8');
	return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, 'ascii'), body]);
}

function encodeLine(message) {
	return JSON.stringify(message) + '\n'; // JSON.stringify never emits a raw newline
}

module.exports = { FrameParser, LineParser, encodeFrame, encodeLine };
