set terminal pdf dashed size 5,4
set output "overhead-vs-workers.pdf"

#set autoscale fix

#set format y "%.0e"
set ylabel "Overhead [ms]" font "Times-Roman,14"
#set ylabel offset +1.2,0
set yrange [1:500]

set xlabel "Number of Workers" font "Times-Roman,14"
#set xlabel offset 0,+1
set xrange [1:100]
set xtics font "Times-Roman,14"
set ytics font "Times-Roman,14"

set logscale xy

set ytics (1,2,3,5,7,10,20,30,50,70,100,200,300,500)
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

plot 'overhead-vs-workers.dat' using 1:5 title "1000 deps" with linespoint lt 1 ps 1 lw 3 lc 1 pt 1, \
     ''                        using 1:4 title "100 deps"  with linespoint lt 1 ps 1 lw 3 lc 3 pt 6, \
     ''                        using 1:3 title "10 deps"   with linespoint lt 1 ps 1 lw 3 lc 4 pt 2, \
     ''                        using 1:2 title "1 deps"    with linespoint lt 1 ps 1 lw 3 lc 2 pt 4
