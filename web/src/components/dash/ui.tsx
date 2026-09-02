import type { ReactNode } from 'react';

export function Panel({
	title,
	hint,
	children,
	wide,
}: {
	title: string;
	hint?: string;
	children: ReactNode;
	wide?: boolean;
}) {
	return (
		<section className={wide ? 'panel panel-wide' : 'panel'}>
			<header>
				<h2>{title}</h2>
				{hint && <p>{hint}</p>}
			</header>
			{children}
		</section>
	);
}

export function Field({
	label,
	value,
	onChange,
	placeholder,
	mono,
}: {
	label: string;
	value: string;
	onChange: (v: string) => void;
	placeholder?: string;
	mono?: boolean;
}) {
	return (
		<label className="field">
			<span>{label}</span>
			<input
				className={mono ? 'mono' : undefined}
				value={value}
				placeholder={placeholder}
				spellCheck={false}
				onChange={(e) => onChange(e.target.value)}
			/>
		</label>
	);
}

export function Row({ label, children }: { label: string; children: ReactNode }) {
	return (
		<div className="row">
			<span className="row-label">{label}</span>
			<span className="row-value">{children}</span>
		</div>
	);
}

export function Addr({ value }: { value?: string }) {
	if (!value || value === '0x0000000000000000000000000000000000000000') return <span className="dim">—</span>;
	return (
		<span className="mono" title={value}>
			{value.slice(0, 6)}…{value.slice(-4)}
		</span>
	);
}

export function Btn({
	children,
	onClick,
	disabled,
	primary,
	busy,
}: {
	children: ReactNode;
	onClick: () => void;
	disabled?: boolean;
	primary?: boolean;
	busy?: boolean;
}) {
	return (
		<button
			type="button"
			className={primary ? 'btn btn-primary' : 'btn'}
			disabled={disabled || busy}
			onClick={onClick}
		>
			{busy ? 'pending…' : children}
		</button>
	);
}

export function Note({ children, tone }: { children: ReactNode; tone?: 'warn' | 'ok' }) {
	return <p className={tone ? `note note-${tone}` : 'note'}>{children}</p>;
}

export function TxState({ hash, error, confirming, confirmed }: {
	hash?: string;
	error?: Error | null;
	confirming?: boolean;
	confirmed?: boolean;
}) {
	if (error) return <Note tone="warn">{error.message.split('\n')[0]}</Note>;
	if (confirmed) return <Note tone="ok">confirmed</Note>;
	if (confirming) return <Note>waiting for confirmation…</Note>;
	if (hash) return <Note>submitted</Note>;
	return null;
}
