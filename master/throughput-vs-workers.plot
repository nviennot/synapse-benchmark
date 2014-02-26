set terminal pdf dashed size 6,4
set output "throughput-vs-worker.pdf"

#set autoscale fix

#set format y "%.0e"
set ylabel "Throughput [msg/s]" font "Times-Roman,14"
#set ylabel offset +1.2,0
set yrange [10:15000]

set xlabel "Number of Workers" font "Times-Roman,14"
#set xlabel offset 0,+1
set xrange [1:100]
set xtics font "Times-Roman,14"
set ytics font "Times-Roman,14"

set logscale xy

set ytics (10,20,30,50,70,100,200,300,500,700,1000,2000,3000,5000,7000,10000,20000,30000)
set xtics (1,2,5,10,20,50,100)
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

plot 'throughput-vs-workers.dat' using 1:2 title "no hashing"       with linespoint lw 4, \
     ''                          using 1:3 title "100000 hash size" with linespoint lw 4, \
     ''                          using 1:4 title "10000 hash size"  with linespoint lw 4, \
     ''                          using 1:5 title "1000 hash size"   with linespoint lw 4, \
     ''                          using 1:6 title "100 hash size"    with linespoint lw 4, \
     ''                          using 1:7 title "10 hash size"     with linespoint lw 4, \
     ''                          using 1:8 title "1 hash size"      with linespoint lw 4
