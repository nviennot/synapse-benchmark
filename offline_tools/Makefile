all: diaspora1.pdf diaspora2.pdf

%.pdf: %.plot
	gnuplot $<

diaspora1.plot: gantt_chart.rb diaspora1.log Makefile diaspora1.plot.extra
	./gantt_chart.rb diaspora1.log -o diaspora1.pdf -v 10,50 -v 145,2635 -r spree_app,90,120 -t  -i diaspora1.plot.extra > $@

diaspora2.plot: gantt_chart.rb diaspora2.log Makefile diaspora2.plot.extra
	SHOW_USERS=1 XTICS=30 ANNOTATE_THREADS=0 ./gantt_chart.rb diaspora2.log -s 322,1300 -i diaspora2.plot.extra -o diaspora2.pdf > $@

diaspora2.log: run_2_users.rb
	./run_2_users.rb
	sleep 1
	mv /tmp/instrumentation.log $@

diaspora1.log: run_1_users.rb
	./run_1_users.rb
	sleep 10
	mv /tmp/instrumentation.log $@
