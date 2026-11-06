// Stadium layout shared by the tickets page and the admin portal:
// ring geometry, every section, and the position of every seat.
(function(){
/* ================= GEOMETRY ================= */
// Each ring is a rounded rectangle band: inner half-size (hx,hy), corner radius r, thickness d.
const RINGS={
  L1:{hx:152,hy:106,r:24,d:30},
  L2:{hx:190,hy:143,r:44,d:25},
  SB:{hx:218,hy:171,r:62,d:13},
  L3:{hx:234,hy:188,r:74,d:68},
};
function cum(R){
  if(R.c) return R.c;
  const Lt=2*(R.hx-R.r), Ls=2*(R.hy-R.r), A=Math.PI*R.r/2;
  R.p=[Lt,A,Ls,A,Lt,A,Ls,A]; R.c=[0];
  for(const l of R.p) R.c.push(R.c[R.c.length-1]+l);
  return R.c;
}
// point on the ring at perimeter position s (clockwise from the top-left straight), pushed outward by off
function pt(R,s,off){
  const c=cum(R), P=c[8]; s=((s%P)+P)%P;
  let i=0; while(i<7 && s>=c[i+1]) i++;
  const t=s-c[i], {hx,hy,r}=R;
  if(i===0) return [-hx+r+t,-hy-off];
  if(i===2) return [hx+off,-hy+r+t];
  if(i===4) return [hx-r-t,hy+off];
  if(i===6) return [-hx-off,hy-r-t];
  const C={1:[hx-r,-hy+r],3:[hx-r,hy-r],5:[-hx+r,hy-r],7:[-hx+r,-hy+r]}[i];
  const a={1:-Math.PI/2,3:0,5:Math.PI/2,7:Math.PI}[i]+t/r;
  return [C[0]+(r+off)*Math.cos(a), C[1]+(r+off)*Math.sin(a)];
}
function bandPath(R,s0,s1,o0,o1){
  const n=Math.max(2,Math.ceil((s1-s0)/2)), pts=[];
  for(let i=0;i<=n;i++) pts.push(pt(R,s0+(s1-s0)*i/n,o0));
  for(let i=n;i>=0;i--) pts.push(pt(R,s0+(s1-s0)*i/n,o1));
  return 'M'+pts.map(p=>p[0].toFixed(2)+','+p[1].toFixed(2)).join('L')+'Z';
}
function rrPath(hx,hy,r){
  return `M${-hx+r},${-hy}H${hx-r}A${r},${r} 0 0 1 ${hx},${-hy+r}V${hy-r}A${r},${r} 0 0 1 ${hx-r},${hy}H${-hx+r}A${r},${r} 0 0 1 ${-hx},${hy-r}V${-hy+r}A${r},${r} 0 0 1 ${-hx+r},${-hy}Z`;
}
const range=(a,b)=>Array.from({length:b-a+1},(_,i)=>a+i);

/* ================= SECTIONS ================= */
function buildSections(){
  const SECTIONS=[], BY={};
  // lay sections along one of the 8 ring pieces: 0 top,1 TR,2 right,3 BR,4 bottom,5 BL,6 left,7 TL
  function lay(ring,piece,items,base){
    const R=RINGS[ring], c=cum(R), a=c[piece], b=c[piece+1];
    const objs=items.map(x=>typeof x==='object'?x:{id:String(x)});
    const tot=objs.reduce((t,o)=>t+(o.w||1),0); let s=a;
    for(const o of objs){
      const len=(b-a)*(o.w||1)/tot;
      const sec=Object.assign({},base,o,{ring,s0:s,s1:s+len});
      if(sec.label===undefined) sec.label=sec.id;
      SECTIONS.push(sec); BY[sec.id]=sec; s+=len;
    }
  }
  const b1={level:1,group:'L1',ph:'p15000',kind:'num',fs:9.5};
  lay('L1',0,[126,127,128,101,102,103,104],b1); lay('L1',1,[105],b1);
  lay('L1',2,range(106,110),b1); lay('L1',3,[111],b1);
  lay('L1',4,range(112,118),b1); lay('L1',5,[119],b1);
  lay('L1',6,range(120,124),b1); lay('L1',7,[125],b1);

  const b2={level:2,group:'L2',ph:'p20000',kind:'num',fs:9.5};
  const plat={group:'PLAT',ph:'pplat',kind:'plat'};
  const gold={group:'GOLD',ph:'phase2',kind:'gold',w:1.3,fs:6.4};
  lay('L2',0,[219,220,{id:'PL1',label:'Platinum 1',w:1.4,fs:6.2,...plat},{id:'PL',label:'Platinum',w:2,fs:8,...plat},{id:'PL2',label:'Platinum 2',w:1.4,fs:6.2,...plat},201,202],b2);
  lay('L2',1,[203],b2); lay('L2',2,range(204,208),b2); lay('L2',3,[209],b2);
  lay('L2',4,[210,...['F01','F02','F03','F04','F05'].map(f=>({id:'G'+f,label:'Gold '+f,...gold})),211],b2);
  lay('L2',5,[212],b2); lay('L2',6,range(213,217),b2); lay('L2',7,[218],b2);

  const bs={level:2,group:'SB',ph:'skybox',kind:'sb',fs:5.6};
  const blank=i=>({id:'sbx'+i,label:'',kind:'blank',group:null});
  lay('SB',0,[348,349,350,{id:'RES',label:'Reserved',w:5,kind:'reserved',group:null,fs:6.6},301,302,303],bs);
  lay('SB',1,[304,305,306],bs); lay('SB',2,range(307,319),bs); lay('SB',3,[320,321,322],bs);
  lay('SB',4,range(323,333),bs); lay('SB',5,[334,335,336],bs); lay('SB',6,range(337,345),bs);
  lay('SB',7,[346,347,blank(1),blank(2),blank(3)],bs);

  const b3={level:3,group:'L3',ph:'general',kind:'num',fs:10.5};
  lay('L3',0,[433,434,435,{id:'MEDIA',label:'Media',w:.8,kind:'media',group:null,fs:8.6},401,402,403],b3);
  lay('L3',1,[404,405],b3); lay('L3',2,range(406,412),b3); lay('L3',3,[413,414],b3);
  lay('L3',4,range(415,421),b3); lay('L3',5,[422,423],b3); lay('L3',6,range(424,430),b3);
  lay('L3',7,[431,432],b3);

  for(const s of SECTIONS) s.name = s.kind==='num' ? 'Section '+s.label : s.kind==='sb' ? 'Box '+s.label : s.label;
  return {SECTIONS,BY};
}

/* ================= SEATS ================= */
// Seats of a section, row by row (row 1 is nearest the pitch), each {x,y,a,row,num}.
function seatRows(s){
  const R=RINGS[s.ring], sig=s.ring==='L1'?2.0:1.7, nR=Math.max(1,Math.floor(R.d/sig)), rows=[];
  for(let k=0;k<nR;k++){
    const off=(k+.5)*R.d/nR, n=Math.max(8,Math.ceil((s.s1-s.s0)/.3)), P=[], L=[0];
    for(let i=0;i<=n;i++){P.push(pt(R,s.s0+(s.s1-s.s0)*i/n,off)); if(i) L.push(L[i-1]+Math.hypot(P[i][0]-P[i-1][0],P[i][1]-P[i-1][1]));}
    const tot=L[n], cnt=Math.floor((tot-sig*.6)/sig), row=[];
    if(cnt>0){
      const m=(tot-cnt*sig)/2; let j=0;
      for(let q=0;q<cnt;q++){
        const target=m+sig*(q+.5);
        while(j<n-1&&L[j+1]<target) j++;
        const f=(target-L[j])/((L[j+1]-L[j])||1);
        row.push({x:P[j][0]+(P[j+1][0]-P[j][0])*f, y:P[j][1]+(P[j+1][1]-P[j][1])*f,
          a:Math.atan2(P[j+1][1]-P[j][1],P[j+1][0]-P[j][0]), row:k+1, num:q+1});
      }
    }
    rows.push(row);
  }
  return {sig,rows};
}

window.Stadium={RINGS,cum,pt,bandPath,rrPath,range,buildSections,seatRows};
})();
