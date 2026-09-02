export type Step = {
  kicker: string;
  tex: string[];
  note?: string;
};

export const derivation: Step[] = [
  {
    kicker: '00 — the question',
    tex: ['x \\cdot y = k'],
    note: 'A swap is about to move this pool. It carries a measurable amount of extractable value. How much is in there, and who should end up with it?',
  },
  {
    kicker: '01 — the potential',
    tex: ['\\varphi(x, y, v) = xv + y - 2\\sqrt{kv}'],
    note: 'Against an external price v, the pool’s arbitrage potential. Zero when the pool already sits at v; otherwise exactly what a rebalancer could take.',
  },
  {
    kicker: '02 — what a trade is worth',
    tex: ['\\Delta\\varphi = \\Delta x \\cdot v + \\Delta y'],
    note: 'The value of one trade to someone who believes the true price is v. Every arbitrageur prices the same trade differently, because each holds a different v. This is the bid.',
  },
  {
    kicker: '03 — the ceiling',
    tex: ['\\mathrm{maxMEV} = \\varphi_0 + \\sum_i \\Delta\\varphi_i'],
    note: 'Starting potential plus every trade in the block. No one can extract more than this — it is the size of the prize, and it is knowable in advance.',
  },
  {
    kicker: '04 — the limit state',
    tex: ['\\delta_{\\text{out}}\\,x_\\ell^{2} + \\delta_{\\text{out}}\\delta_{\\text{in}}\\,x_\\ell - k\\,\\delta_{\\text{in}} = 0'],
    note: 'How far the pool can be pushed before the swapper’s own limit price stops binding. Beyond it the trade simply fails, so this is the true edge of a front-run.',
  },
  {
    kicker: '05 — solved',
    tex: [
      'x_\\ell = \\frac{\\sqrt{b^{2} + 4ak\\delta_{\\text{in}}} - b}{2a}, \\qquad y_\\ell = \\frac{k}{x_\\ell}',
      'a = \\delta_{\\text{out}}, \\qquad b = \\delta_{\\text{out}}\\,\\delta_{\\text{in}}',
    ],
    note: 'Closed form, evaluated on-chain. The hook pushes the pool precisely to this point and not one tick further.',
  },
  {
    kicker: '06 — the auction',
    tex: ['w = \\arg\\max_i \\; \\Delta\\varphi_i'],
    note: 'Arbitrageurs stake, post the price they believe, and are scored on the value that belief implies. The highest wins the right to run the bundle.',
  },
  {
    kicker: '07 — second price',
    tex: ['\\mathrm{pay}(w) = \\Delta\\varphi_{(2)}'],
    note: 'The winner pays the runner-up’s valuation, never their own. That single choice makes bidding your honest belief the dominant strategy.',
  },
  {
    kicker: '08 — where it lands',
    tex: ['\\underbrace{\\text{refund}}_{\\text{swapper}} \\;+\\; \\underbrace{\\text{donation}}_{\\text{LPs}} \\;=\\; \\Delta\\varphi_{(2)}'],
    note: 'The payment settles back through the pool itself — to the swapper on the trade path, to liquidity providers on the rebalancing path.',
  },
  {
    kicker: '09 — what is left',
    tex: ['\\text{searcher keeps} \\;=\\; \\Delta\\varphi_{(1)} - \\Delta\\varphi_{(2)}'],
    note: 'Only the gap between the best belief and the second-best. Add competition and it goes to zero. The MEV does not vanish — it changes hands.',
  },
];
