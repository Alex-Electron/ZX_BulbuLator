	.global start
start:
	ldr	sp, =0x00030000        @ stack below the app (app loads at 0x00100000)
	bl	main
spin:	b	spin
	.section .note.GNU-stack,"",%progbits
