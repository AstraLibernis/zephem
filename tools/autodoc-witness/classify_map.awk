# SPDX-License-Identifier: GPL-3.0-or-later
# in: map.tsv find.tsv ; out: mapcheck.tsv
BEGIN{FS=OFS="\t"}
NR==FNR{vis[$1]=$4;kind[$1]=$2;loc[$1]=$5;next}
{p=$1; shape="plain"; if(p ~ /\.\[[^]]*\]/) shape="variant"; else if (p ~ /\.@"[^"]*\.zig"/) shape="filenode";
 ap=(vis[p]=="pub"); q=p; while (ap && match(q, /\.[^.]*$/)) { q=substr(q,1,RSTART-1); if ((q in vis) && vis[q]!="pub") ap=0 }
 if ($2=="-") res="unresolved";
 else if ($3==loc[p]) res="same_loc";
 else if ($6==loc[p]) res="alias_target_loc";
 else { split($3,a,":"); split(loc[p],b,":"); if (a[1]==b[1] && b[2]-a[2]>=0 && b[2]-a[2]<=12 && p ~ /\(\)$/) res="factory_ret_loc"; else res="diff_loc" }
 print p,kind[p],vis[p],ap,shape,res,loc[p],$3,$4,$5,$6,$7}
