all: diaspora1.pdf

%.pdf: %.plot
	gnuplot $<

diaspora1.plot: gantt_chart.rb diaspora1.log
	./gantt_chart.rb diaspora1.log -o diaspora1.pdf -v 10,50 -v 175,2660 -r spree_app,100,120 -t > $@
