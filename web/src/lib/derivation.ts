export type Step = {
	kicker: string;
	tex: string[];
	note?: string;
	figure?: string;
};

// A shared constant-product curve y = k/x, sampled across x ∈ [0.4, 2.8] in a 300×170 box.
const CURVE = '20,22 31,52 47,80 69,101 96,117 128,129 172,139 226,146 280,151';

export const derivation: Step[] = [
	{
		kicker: '00 — the question',
		tex: ['x \\cdot y = k'],
		note: 'A swap is about to move this pool. The only question the hook asks: is it being filled on the wrong side of what the market believes the pair is worth?',
		figure: `<svg viewBox="0 0 300 170" role="img" aria-label="The constant-product curve with the pool's current point.">
			<line class="fig-axis" x1="20" y1="151" x2="288" y2="151"/>
			<line class="fig-axis" x1="20" y1="12" x2="20" y2="151"/>
			<polyline class="fig-curve" points="${CURVE}"/>
			<circle class="fig-mark" cx="96" cy="117" r="4"/>
			<text class="fig-label" x="96" y="107" text-anchor="middle">pool (x, y)</text>
			<text class="fig-axis-label" x="284" y="165" text-anchor="end">x</text>
			<text class="fig-axis-label" x="12" y="18">y</text>
		</svg>`,
	},
	{
		kicker: '01 — the potential',
		tex: ['\\varphi(x, y, v) = xv + y - 2\\sqrt{kv}'],
		note: 'Against an external price v, the pool’s arbitrage potential — the value of its holdings at v minus what it would hold if already priced at v. Zero at v; positive otherwise.',
		figure: `<svg viewBox="0 0 300 170" role="img" aria-label="Two parallel price lines of slope −v; the gap between them is the potential φ.">
			<polyline class="fig-curve" points="${CURVE}"/>
			<line class="fig-line" x1="34" y1="150" x2="214" y2="18"/>
			<line class="fig-line-dash" x1="76" y1="150" x2="256" y2="18"/>
			<polygon class="fig-area" points="34,150 214,18 256,18 76,150"/>
			<circle class="fig-mark" cx="118" cy="92" r="3.5"/>
			<circle class="fig-dot" cx="150" cy="122" r="3"/>
			<text class="fig-label" x="240" y="52">φ</text>
			<text class="fig-label" x="150" y="140" text-anchor="middle">rebalanced at v</text>
		</svg>`,
	},
	{
		kicker: '02 — what a trade is worth',
		tex: ['\\Delta\\varphi = \\Delta x \\cdot v + \\Delta y'],
		note: 'The value of one trade to someone who believes the true price is v. Every arbitrageur prices the same trade differently, because each holds a different v. This is the bid.',
		figure: `<svg viewBox="0 0 300 170" role="img" aria-label="A trade slides the pool along the curve; its value at belief v is Δφ.">
			<defs><marker id="dv-a" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 0L10 5L0 10z" fill="var(--fig-accent)"/></marker></defs>
			<polyline class="fig-curve" points="${CURVE}"/>
			<path class="fig-vec" d="M69 101 Q 98 108 128 129" marker-end="url(#dv-a)"/>
			<circle class="fig-dot" cx="69" cy="101" r="3.5"/>
			<circle class="fig-mark" cx="128" cy="129" r="3.5"/>
			<line class="fig-line-dash" x1="69" y1="101" x2="69" y2="151"/>
			<line class="fig-line-dash" x1="128" y1="129" x2="128" y2="151"/>
			<text class="fig-label" x="98" y="93" text-anchor="middle">Δx, Δy</text>
			<text class="fig-label" x="98" y="164" text-anchor="middle">scored at v → Δφ</text>
		</svg>`,
	},
	{
		kicker: '03 — the fair region',
		tex: ['[\\,v_{(2)},\\; v_{(1)}\\,]'],
		note: 'Arbitrageurs stake and post the price they believe. The best and runner-up live beliefs bracket the region the competitive market thinks the pair is worth. No oracle — just staked quotes.',
		figure: `<svg viewBox="0 0 300 170" role="img" aria-label="A price axis with a shaded band between the runner-up belief and the best belief.">
			<line class="fig-axis" x1="24" y1="110" x2="284" y2="110"/>
			<rect class="fig-area" x="120" y="70" width="86" height="40"/>
			<line class="fig-cut" x1="120" y1="60" x2="120" y2="120"/>
			<line class="fig-cut" x1="206" y1="60" x2="206" y2="120"/>
			<circle class="fig-dot" cx="120" cy="110" r="3.5"/>
			<circle class="fig-mark" cx="206" cy="110" r="3.5"/>
			<text class="fig-label" x="120" y="52" text-anchor="middle">v₍₂₎</text>
			<text class="fig-label" x="206" y="52" text-anchor="middle">v₍₁₎</text>
			<text class="fig-label" x="163" y="134" text-anchor="middle">fair region</text>
			<text class="fig-axis-label" x="284" y="126" text-anchor="end">price</text>
		</svg>`,
	},
	{
		kicker: '04 — the trigger',
		tex: ['\\lvert\\, p_{\\text{end}} - v_{(2)} \\rvert \\;>\\; \\lvert\\, p_{\\text{now}} - v_{(2)} \\rvert'],
		note: 'The hook simulates the vanilla swap. It acts only if the trade ends further from the fair region than it started — equivalently, the runner-up belief sits on the swapper’s favourable side. A trade moving toward fair is left untouched.',
		figure: `<svg viewBox="0 0 300 170" role="img" aria-label="A price axis: current price, the fair edge, and a vanilla end price that lands further from the edge.">
			<line class="fig-axis" x1="24" y1="100" x2="284" y2="100"/>
			<line class="fig-cut" x1="196" y1="52" x2="196" y2="120"/>
			<text class="fig-label" x="196" y="44" text-anchor="middle">v₍₂₎</text>
			<circle class="fig-dot" cx="150" cy="100" r="3.5"/>
			<text class="fig-label" x="150" y="88" text-anchor="middle">p_now</text>
			<circle class="fig-mark" cx="70" cy="100" r="4"/>
			<text class="fig-label" x="70" y="88" text-anchor="middle">p_end</text>
			<line class="fig-brace" x1="70" y1="118" x2="196" y2="118"/>
			<line class="fig-line-dash" x1="150" y1="118" x2="150" y2="112"/>
			<text class="fig-label" x="120" y="134" text-anchor="middle">further from fair → act</text>
		</svg>`,
	},
	{
		kicker: '05 — the fill price',
		tex: ['p_{\\text{hook}} = p_{\\text{pool}} + (1 - e)\\,\\bigl(v_{(2)} - p_{\\text{pool}}\\bigr)'],
		note: 'The price the hook offers on its slice of the order: between the pool and the runner-up belief, keeping a fixed margin e. Never the best belief — so no single aggressive quote moves the fill.',
		figure: `<svg viewBox="0 0 300 170" role="img" aria-label="A price axis: the pool price, the hook fill price a fraction of the way toward v2, and v2.">
			<line class="fig-axis" x1="24" y1="100" x2="284" y2="100"/>
			<circle class="fig-dot" cx="60" cy="100" r="3.5"/>
			<text class="fig-label" x="60" y="88" text-anchor="middle">p_pool</text>
			<circle class="fig-mark" cx="176" cy="100" r="4.5"/>
			<text class="fig-label" x="176" y="88" text-anchor="middle">p_hook</text>
			<line class="fig-cut" x1="236" y1="60" x2="236" y2="118"/>
			<text class="fig-label" x="236" y="52" text-anchor="middle">v₍₂₎</text>
			<line class="fig-brace" x1="176" y1="118" x2="236" y2="118"/>
			<text class="fig-label" x="206" y="134" text-anchor="middle">margin e → LPs</text>
		</svg>`,
	},
	{
		kicker: '06 — the partial fill',
		tex: [
			'\\delta_{\\text{in}}^{\\,h} = f \\cdot \\delta_{\\text{in}}, \\qquad \\delta_{\\text{out}}^{\\,h} = \\delta_{\\text{in}}^{\\,h}\\, p_{\\text{hook}}',
			'f \\le \\texttt{MAX\\_FILL\\_BPS}',
		],
		note: 'The hook takes up to a fraction f of the input from its buffer and hands back output at p_hook. The remaining (1 − f) of the order routes to the pool as a smaller swap.',
		figure: `<svg viewBox="0 0 300 170" role="img" aria-label="One bar for the order split into a hook-filled slice and a larger pool slice.">
			<line class="fig-axis" x1="24" y1="150" x2="284" y2="150"/>
			<rect class="fig-bar-hi" x="96" y="112" width="108" height="38"/>
			<rect class="fig-bar" x="96" y="54" width="108" height="56"/>
			<line class="fig-cut" x1="88" y1="112" x2="212" y2="112"/>
			<text class="fig-label" x="220" y="134">hook fills · f</text>
			<text class="fig-label" x="220" y="84">rest → pool</text>
			<line class="fig-brace" x1="88" y1="54" x2="88" y2="150"/>
			<text class="fig-label" x="80" y="104" text-anchor="end">δ_in</text>
		</svg>`,
	},
	{
		kicker: '07 — vanilla-or-better',
		tex: [
			'\\text{out}_{\\text{hooked}} = \\text{pool}\\bigl(\\delta_{\\text{in}} - \\delta_{\\text{in}}^{\\,h}\\bigr) + \\delta_{\\text{out}}^{\\,h} \\;\\ge\\; \\text{out}_{\\text{vanilla}}',
		],
		note: 'The hook slice is priced above the pool, and the pool slice is smaller so it slips less. Their sum beats the untouched execution — strictly, every time the hook acts. This is a precondition, not a hope: if it fails to clear, the hook stays out.',
		figure: `<svg viewBox="0 0 300 170" role="img" aria-label="Two bars: vanilla output and the taller hooked output, the small difference marked as gain.">
			<line class="fig-axis" x1="24" y1="150" x2="284" y2="150"/>
			<rect class="fig-bar" x="78" y="74" width="34" height="76"/>
			<rect class="fig-bar-hi" x="150" y="58" width="34" height="92"/>
			<line class="fig-cut" x1="70" y1="74" x2="192" y2="74"/>
			<rect class="fig-area" x="196" y="58" width="14" height="16"/>
			<text class="fig-label" x="95" y="66" text-anchor="middle">vanilla</text>
			<text class="fig-label" x="167" y="50" text-anchor="middle">hooked</text>
			<text class="fig-label" x="218" y="70">your gain</text>
		</svg>`,
	},
	{
		kicker: '08 — the sweep',
		tex: ['\\mathrm{pay}(w) = \\mathrm{inv}\\cdot v_{(2)}, \\qquad \\text{searcher keeps} = \\mathrm{inv}\\cdot\\bigl(v_{(1)} - v_{(2)}\\bigr)'],
		note: 'The fill leaves the hook holding inventory bought slightly cheap. A solver buys it at the runner-up belief — second price — and hedges externally, keeping only the gap to the best belief. Add bidders and that gap compresses.',
		figure: `<svg viewBox="0 0 300 170" role="img" aria-label="The winner's bar with a line drawn across at the runner-up's height; the sliver above is what the searcher keeps.">
			<line class="fig-axis" x1="24" y1="150" x2="284" y2="150"/>
			<rect class="fig-bar" x="60" y="104" width="34" height="46"/>
			<rect class="fig-bar-hi" x="110" y="52" width="34" height="98"/>
			<rect class="fig-bar" x="160" y="82" width="34" height="68"/>
			<line class="fig-cut" x1="44" y1="70" x2="210" y2="70"/>
			<text class="fig-label" x="216" y="74">pays v₍₂₎</text>
			<text class="fig-label" x="127" y="44" text-anchor="middle">wins</text>
		</svg>`,
	},
	{
		kicker: '09 — where it lands',
		tex: [
			'\\underbrace{\\text{refill}}_{\\text{buffer}} \\;+\\; \\underbrace{\\text{donation}}_{\\text{LPs}} \\;=\\; \\mathrm{inv}\\cdot v_{(2)} - \\text{cost}',
		],
		note: 'The swapper was already made whole up front, in the fill. The sweep restores the buffer to its cost basis and donates the rest straight to in-range LPs. Nothing leaves the pool’s ecosystem.',
		figure: `<svg viewBox="0 0 300 170" role="img" aria-label="One bar split into a buffer-refill segment and a donation segment summing to the sweep proceeds minus cost.">
			<line class="fig-axis" x1="24" y1="150" x2="284" y2="150"/>
			<rect class="fig-bar" x="120" y="96" width="60" height="54"/>
			<rect class="fig-area" x="120" y="52" width="60" height="44"/>
			<line class="fig-cut" x1="112" y1="96" x2="188" y2="96"/>
			<text class="fig-label" x="196" y="126">refill → buffer</text>
			<text class="fig-label" x="196" y="78">donation → LPs</text>
			<line class="fig-brace" x1="112" y1="52" x2="112" y2="150"/>
			<text class="fig-label" x="104" y="104" text-anchor="end">v₍₂₎ − cost</text>
		</svg>`,
	},
];
