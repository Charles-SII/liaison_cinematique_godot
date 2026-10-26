extends RefCounted
## Mobilités de Liaisons_Symbolisation.pdf, page 1.
## Ordre des composantes : Tx, Ty, Tz, Rx, Ry, Rz.
## Le premier pivot est conservé du prototype initial ; les 11 autres
## entrées correspondent au document (la glissière existait déjà).
const ENTRIES := [
	{"name": "Pivot (prototype)", "center": "O", "geometry": "axe Z", "dof": [0,0,0,0,0,1], "count": 1, "motion": "1 rotation suivant Z"},
	{"name": "Glissière", "center": "A", "geometry": "axe X", "dof": [1,0,0,0,0,0], "count": 1, "motion": "1 translation suivant X"},
	{"name": "Encastrement", "center": "B", "geometry": "fixe", "dof": [0,0,0,0,0,0], "count": 0, "motion": "aucun mouvement relatif"},
	{"name": "Pivot", "center": "A", "geometry": "axe X", "dof": [0,0,0,1,0,0], "count": 1, "motion": "1 rotation suivant X"},
	{"name": "Pivot glissant", "center": "C", "geometry": "axe X", "dof": [1,0,0,1,0,0], "count": 2, "motion": "translation et rotation X indépendantes"},
	{"name": "Hélicoïdale", "center": "B", "geometry": "axe X", "dof": [1,0,0,1,0,0], "count": 1, "motion": "Tx et Rx liées : Tx = pas × Rx / 2π"},
	{"name": "Rotule / sphérique", "center": "O", "geometry": "centre fixe", "dof": [0,0,0,1,1,1], "count": 3, "motion": "3 rotations"},
	{"name": "Linéaire annulaire / circulaire", "center": "B", "geometry": "axe X", "dof": [1,0,0,1,1,1], "count": 4, "motion": "1 translation X et 3 rotations"},
	{"name": "Rotule à doigt", "center": "O", "geometry": "Rz bloquée", "dof": [0,0,0,1,1,0], "count": 2, "motion": "2 rotations : Rx et Ry"},
	{"name": "Appui plan", "center": "D", "geometry": "normale Z", "dof": [1,1,0,0,0,1], "count": 3, "motion": "2 translations X, Y et 1 rotation Z"},
	{"name": "Linéaire rectiligne", "center": "C", "geometry": "axe X, normale Z", "dof": [1,1,0,1,0,1], "count": 4, "motion": "Tx, Ty, Rx et Rz"},
	{"name": "Ponctuelle", "center": "O", "geometry": "normale Z", "dof": [1,1,0,1,1,1], "count": 5, "motion": "2 translations X, Y et 3 rotations"},
]
