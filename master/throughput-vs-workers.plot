set terminal pdf dashed size 4,3
set output "throughput-vs-worker.pdf"

#set autoscale fix

#set format y "%.0e"
set ylabel "Throughput [msg/s]" font "Times-Roman,14"
#set ylabel offset +1.2,0
set yrange [100:25000]

set xlabel "Number of Workers" font "Times-Roman,14"
#set xlabel offset 0,+1
set xrange [1:200]
set xtics font "Times-Roman,14"
set ytics font "Times-Roman,14"

set logscale xy

set ytics (100,200,300,400,600,800,1000,2000,3000,4000,6000,8000,10000,20000,30000)
set xtics (1,3,5,10,30,50,100,175)
set grid ytics
set grid xtics
# set ytics 250 font "Times-Roman,14"

#set data style boxes
#set boxwidth 0.9
# set style fill solid 1.0

# set multiplot
set key reverse top left font "Times-Roman,14"

# set boxwidth 0.6
# set style fill solid 0.5 border

set datafile missing

plot 'throughput-vs-workers.dat' using 1:4 title "10000 users" with linespoint lt 1 ps 1 lw 3 lc 1 pt 1, \
     ''                          using 1:3 title "1000 users"  with linespoint lt 1 ps 1 lw 3 lc 3 pt 6, \
     ''                          using 1:2 title "100 users"   with linespoint lt 1 ps 1 lw 3 lc 4 pt 2
