set terminal pdf dashed size 4,3
set output "throughput-vs-worker.pdf"

#set autoscale fix

#set format y "%.0e"
set ylabel "Throughput [msg/s]" font "Times-Roman,14"
#set ylabel offset +1.2,0
set yrange [5:5000]

set xlabel "Number of Workers" font "Times-Roman,14"
#set xlabel offset 0,+1
set xrange [1:300]
set xtics font "Times-Roman,14"
set ytics font "Times-Roman,14"

set logscale xy

# set ytics 0.001,10,1000
set grid ytics
# set ytics 250 font "Times-Roman,14"

#set data style boxes
#set boxwidth 0.9
# set style fill solid 1.0

# set multiplot
set key reverse top left font "Times-Roman,14"

# set boxwidth 0.6
# set style fill solid 0.5 border

plot 'throughput-vs-workers.dat' using 1:5 title "3000 users" with linespoint lt 1 ps 1 lw 3 lc 1 pt 1, \
     ''                          using 1:4 title "300 users"  with linespoint lt 1 ps 1 lw 3 lc 3 pt 6, \
     ''                          using 1:3 title "30 users"   with linespoint lt 1 ps 1 lw 3 lc 4 pt 2, \
     ''                          using 1:2 title "3 users"    with linespoint lt 1 ps 1 lw 3 lc 2 pt 4, \
